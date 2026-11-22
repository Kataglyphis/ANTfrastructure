"""Remove explicitly reviewed disposable venvs; supplied authorization is not authenticated and observations are not locks."""

from __future__ import annotations

import hashlib
import os
import runpy
import shutil
import stat
import subprocess
from functools import cache
from pathlib import Path
from typing import Any, cast

from host_commands import checked_output
from qa_venv_usage import observe_usage
from source_ci.common import fingerprint, read, require, save, timestamp


@cache
def relocation_api() -> dict[str, Any]:
    api = runpy.run_path(str(Path(__file__).with_name('relocate-quality-venv.py')))
    require(all(callable(api.get(name)) for name in ('validate_source', 'allocated_regular_bytes', 'tree_digest')),
            'The canonical quality environment validator is incomplete')
    return api


def source_state(root: Path) -> dict[str, str]:
    command = ['git', '--no-optional-locks', '-C', str(root)]
    index = checked_output([*command, 'ls-files', '--stage', '-z'])
    diff = checked_output([*command, 'diff', '--no-ext-diff', '--binary', 'HEAD', '--'])
    return {'head': checked_output([*command, 'rev-parse', 'HEAD']).strip(),
            'index_sha256': hashlib.sha256(index.encode()).hexdigest(),
            'diff_sha256': hashlib.sha256(diff.encode()).hexdigest(),
            'lock_sha256': fingerprint(root / 'quality/uv.lock')}


def validate_boundary(path: Path, root: Path, protected: list[Path], output: Path) -> None:
    require(path.is_absolute() and path == path.resolve(strict=True) and path.is_relative_to(root),
            'Selected environment escapes its literal allowed root')
    require(not any(path.is_relative_to(p.resolve()) or p.resolve().is_relative_to(path) for p in protected),
            'Selected environment overlaps a protected path')
    require(not output.is_relative_to(path) and not path.is_relative_to(output), 'Proof directory overlaps selection')


def selected_paths(review: Path, root: Path, protected: list[Path], output: Path) -> list[Path]:
    require(__debug__, 'Optimization disables prerequisite safety assertions')
    require(root.is_absolute() and root == root.resolve(strict=True), 'Allowed root must be literal and absolute')
    require(protected and all(path.is_absolute() for path in protected), 'Explicit protected paths are required')
    rows = read(review)['candidates']
    require(isinstance(rows, list) and rows, 'The reviewed candidate list is empty')
    paths = [Path(row['environment']) for row in rows]
    require(len(paths) == len(set(paths)), 'Duplicate QA selection')
    for path in paths:
        validate_boundary(path, root, protected, output)
        require(not any(other != path and other.is_relative_to(path) for other in paths), 'Overlapping QA selections')
    return paths


def candidate_state(path: Path) -> dict[str, Any]:
    api = relocation_api()
    api['validate_source'](path)
    metadata = path.lstat()
    require(stat.S_ISDIR(metadata.st_mode) and metadata.st_uid == os.getuid(), 'QA tree is not an owned plain directory')
    require((path.parent / 'pyproject.toml').is_file(), 'Recreation project metadata is missing')
    for _parent, directories, files in os.walk(path, followlinks=False):
        require('.git' not in directories + files, 'A QA tree contains a versioned source checkout')
    return {'environment': str(path), 'device': metadata.st_dev, 'inode': metadata.st_ino,
            'mode': stat.S_IMODE(metadata.st_mode), 'allocated_regular_bytes': api['allocated_regular_bytes'](path),
            'tree_sha256': api['tree_digest'](path), 'source': source_state(path.parent.parent)}


def verify_candidate(row: dict[str, Any]) -> None:
    require(candidate_state(Path(row['environment'])) == row, 'Reviewed environment or owning source changed')


def verify_inputs(inputs: dict[str, str]) -> None:
    require(all(fingerprint(Path(path)) == digest for path, digest in inputs.items()), 'Cleanup inputs changed')


def authorize(path: Path | None, root: Path) -> dict[str, Any]:
    require(path is not None and path.is_file() and not path.is_symlink(), 'Apply requires an authorization record')
    path = cast(Path, path)
    record = read(path)
    require(record.get('scope') == 'standing-automatic-cleanup-of-unused-reproducible-QA-outputs'
            and 'ignored-quality-venv' in record.get('approved_categories', []), 'QA removal is not in the supplied authorization')
    require(record.get('allowed_root') == str(root), 'Authorization allowed root differs')
    return {'path': str(path), 'sha256': fingerprint(path), 'authenticated': False}


def remove_candidate(row: dict[str, Any], paths: list[Path], engine: str,
                     inputs: dict[str, str]) -> dict[str, Any]:
    usage = observe_usage(paths, engine)
    verify_candidate(row)
    verify_inputs(inputs)
    path = Path(row['environment'])
    require(shutil.rmtree.avoids_symlink_attacks, 'Symlink-resistant deletion is required')
    shutil.rmtree(path)
    path.mkdir(mode=row['mode'])
    require(not any(path.iterdir()), 'QA mountpoint is not empty after removal')
    require(source_state(path.parent.parent) == row['source'], 'Owning versioned source or lock changed')
    return {'environment': str(path), 'empty_mountpoint_retained': True,
            'allocated_regular_bytes_selected': row['allocated_regular_bytes'], 'usage': usage}


def cleanup(review: Path, root: Path, protected: list[Path], output: Path, engine: str,
            authorization: Path | None = None, apply: bool = False) -> dict[str, Any]:
    require(output.is_absolute() and output.parent == output.parent.resolve(strict=True), 'Proof parent must be literal')
    require(not output.exists() and not output.is_symlink(), 'Preserve existing cleanup evidence')
    paths = selected_paths(review, root, protected, output)
    authority = authorize(authorization, root) if apply else None
    inputs = {str(review): fingerprint(review)}
    if authority:
        inputs[authority['path']] = authority['sha256']
    usage = observe_usage(paths, engine)
    rows = [candidate_state(path) for path in paths]
    verify_inputs(inputs)
    output.mkdir()
    record = {'observed_at': timestamp(), 'status': 'dry-run', 'inputs_sha256': inputs,
              'authorization': authority, 'usage': usage, 'candidates': rows, 'removed': [],
              'before_free_bytes': shutil.disk_usage(root).free, 'source_build_or_runtime_acceptance': False}
    save(output / 'preview.json', record)
    try:
        for row in rows:
            verify_candidate(row)
        if apply:
            for index, row in enumerate(rows, 1):
                removed = remove_candidate(row, paths, engine, inputs)
                save(output / f'removed-{index}.json', removed)
                record['removed'].append(removed)
            record['status'] = 'completed-approved-QA-venv-removal'
        record['after_free_bytes'] = shutil.disk_usage(root).free
        verify_inputs(inputs)
        save(output / 'receipt.json', record)
    except (AssertionError, OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        save(output / 'failure.json', {**record, 'status': 'failed', 'error': str(error)})
        raise
    return record
