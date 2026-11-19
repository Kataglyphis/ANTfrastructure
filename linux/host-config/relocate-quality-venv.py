#!/usr/bin/env python3
"""Retain a closed ignored quality venv on tmpfs; no build, runtime, concurrent-writer or reboot-persistence proof."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


def tree_digest(root: Path) -> str:
    command = ['timeout', '--kill-after=5s', '45s', 'tar', '--sort=name', '--format=gnu',
               '--numeric-owner', '-cf', '-', '-C', str(root), '.']
    with tempfile.TemporaryFile() as errors, subprocess.Popen(command, stdout=subprocess.PIPE, stderr=errors) as process:
        assert process.stdout is not None
        digest = hashlib.sha256()
        while chunk := process.stdout.read(1024 * 1024):
            digest.update(chunk)
        status = process.wait(timeout=55)
        if status:
            errors.seek(0)
            raise RuntimeError(f'Environment archive failed ({status}): {errors.read(4096).decode(errors="replace")}')
    return digest.hexdigest()


def validate_source(source: Path) -> None:
    assert source.is_absolute() and source == source.resolve(strict=True) and not source.is_symlink(), 'Environment path must be literal and absolute'
    assert source.name == '.venv' and source.parent.name == 'quality' and (source / 'pyvenv.cfg').is_file(), 'Select only a quality virtual environment'
    repo = source.parent.parent
    assert (repo / 'AGENTS.md').is_file() and (repo / 'quality/uv.lock').is_file(), 'Owning source and lock are required'
    tracked = subprocess.check_output(['git', '--no-optional-locks', '-C', str(repo), 'ls-files', '--', 'quality/.venv'], timeout=20)
    assert not tracked, 'Never relocate versioned files'
    subprocess.run(['git', '--no-optional-locks', '-C', str(repo), 'check-ignore', '--quiet', '--', 'quality/.venv'], check=True, timeout=20)


def filesystem(path: Path) -> tuple[int, set[str]]:
    kinds = subprocess.check_output(['findmnt', '--noheadings', '--output', 'FSTYPE', '--target', str(path)], text=True, timeout=10)
    return path.stat().st_dev, set(kinds.splitlines())


def validate_target(source: Path, target: Path, output: Path) -> None:
    assert target.is_absolute() and target.parent == target.parent.resolve(strict=True), 'Destination parent must be literal and absolute'
    assert target.name.startswith('ant-quality-venv-') and not target.exists() and not target.is_symlink(), 'Preserve existing destinations'
    assert not output.exists() and not output.is_symlink(), 'Preserve existing relocation evidence'
    device, kinds = filesystem(target.parent)
    assert kinds == {'tmpfs'} and source.stat().st_dev != device, 'Select a different existing tmpfs filesystem'


def allocated_regular_bytes(source: Path) -> int:
    allocated = 0
    for root, dirs, files in os.walk(source, followlinks=False):
        for name in dirs + files:
            entry = (Path(root) / name).lstat()
            if stat.S_ISREG(entry.st_mode):
                assert entry.st_nlink == 1, 'Preserve shared cache inodes'
                allocated += entry.st_blocks * 512
            else:
                assert stat.S_ISDIR(entry.st_mode) or stat.S_ISLNK(entry.st_mode), 'Only directories, regular files and links are supported'
    return allocated


def relocate(source: Path, target: Path, output: Path) -> dict[str, object]:
    validate_source(source)
    validate_target(source, target, output)
    allocated = allocated_regular_bytes(source)
    free = os.statvfs(target.parent)
    assert free.f_bavail * free.f_frsize >= allocated + 1024**3, 'Retain one GiB of tmpfs headroom'
    before = tree_digest(source)
    free = os.statvfs(source)
    available = free.f_bavail * free.f_frsize
    output.mkdir()
    invocation: dict[str, object] = {'source':str(source), 'target':str(target), 'allocated_regular_bytes':allocated, 'before_gnu_tar_sha256':before}
    (output / 'invocation.json').write_text(json.dumps(invocation, indent=2) + '\n')
    shutil.move(str(source), str(target))
    assert not source.exists() and target.is_dir() and not target.is_symlink(), 'Relocation did not complete'
    assert tree_digest(target) == before, 'Retained environment bytes or metadata differ'
    source.mkdir()
    current = os.statvfs(source)
    result = dict(invocation, status='retained-closed-ignored-quality-venv-on-existing-tmpfs',
                  observed_at=datetime.datetime.now(datetime.UTC).isoformat(),
                  source_mountpoint_retained_empty=True, before_source_free_bytes=available,
                  after_source_free_bytes=current.f_bavail * current.f_frsize,
                  exact_contents_and_GNU_tar_metadata_retained=True, scope=__doc__)
    (output / 'receipt.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['environment', 'target', 'directory']:
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(relocate(args.environment, args.target, args.directory)))
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (AssertionError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'Quality venv relocation refused: {error}', file=sys.stderr)
        raise SystemExit(2) from error
