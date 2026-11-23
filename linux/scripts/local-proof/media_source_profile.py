"""Admit a Media source that changes nothing a compiler, SDK or ROCm GPU image reads; no build, cache-hit or acceptance proof."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path
from typing import TYPE_CHECKING

from normal_stage_launch import full_source
from proof_commands import checked_run

if TYPE_CHECKING:
    from proof_types import Json

UPSTREAM_DOCKERFILES = ('linux/Dockerfile.base', 'linux/Dockerfile.toolchain', 'linux/Dockerfile.sdk', 'linux/Dockerfile.amd')
FIXED_INPUTS = ('.dockerignore', 'linux/.dockerignore', *UPSTREAM_DOCKERFILES)
_MOUNT_SOURCE = re.compile(r'\bsource=([^,\s\\]+)')
_COPY = re.compile(r'^\s*(?:ADD|COPY)\s+(.+)$', re.MULTILINE)


def _literal_prefix(path: str) -> str:
    """Cut an ARG-expanded path at its first variable so the comparison covers every expansion."""
    head = path.split('$', 1)[0]
    return head if head == path else head.rsplit('/', 1)[0]


def dockerfile_inputs(text: str) -> set[str]:
    """Every build-context path an upstream Dockerfile mounts or copies, as literal prefixes."""
    paths = {_literal_prefix(value) for value in _MOUNT_SOURCE.findall(text)}
    for line in _COPY.findall(text.replace('\\\n', ' ')):
        words = line.split()
        if any(word.startswith('--from') for word in words):
            continue
        paths |= {_literal_prefix(word) for word in words[:-1] if not word.startswith('--')}
    return {path.strip('/') for path in paths if path.strip('/') and not path.startswith('/')}


def _object(repository: Path, revision: str, path: str) -> str:
    result = subprocess.run(['git', '-C', str(repository), 'rev-parse', '--verify', '--quiet', f'{revision}:{path}'],
                            capture_output=True, text=True, check=False, timeout=60)
    if result.returncode not in {0, 1}:
        raise subprocess.CalledProcessError(result.returncode, result.args, result.stdout, result.stderr)
    return result.stdout.strip() if result.returncode == 0 else '<absent>'


def _closures(root: Path) -> dict[str, object]:
    sys.path.insert(0, str(root / 'linux/scripts'))
    try:
        import script_closure
        profiles = {name: script_closure.profile_for(root / name) for name in UPSTREAM_DOCKERFILES}
        return {name: script_closure.closure_files(root / 'linux/scripts', profile)[1]
                for name, profile in profiles.items() if profile}
    finally:
        sys.path.pop(0)
        sys.modules.pop('script_closure', None)


def select_media_source(gpu: Json, selected: Path, proof_path: Path) -> tuple[Path, str, Path, Json]:
    """Return the Media source, revision, proof and review, or refuse an upstream input change."""
    producer = Path(str(gpu['source'])).resolve(strict=True)
    source = selected.resolve(strict=True)
    assert gpu['variant'] == 'rocm' and gpu['stage'] == 'gpu', 'Alternate Media source is reviewed for ROCm GPU parents only'
    assert source != producer, 'Alternate Media source must be distinct'
    parent = str(gpu['source_revision'])
    head = checked_run(['git', '-C', str(source), 'rev-parse', 'HEAD']).stdout.strip()
    assert head != parent, 'Alternate Media source must be a different revision'
    checked_run(['git', '-C', str(source), 'merge-base', '--is-ancestor', parent, head])
    full = full_source(source, proof_path, head)
    changed = sorted(filter(None, checked_run(['git', '-C', str(source), 'diff', '--name-only', parent, head]).stdout.splitlines()))
    inputs = set(FIXED_INPUTS)
    for name in UPSTREAM_DOCKERFILES:
        inputs |= dockerfile_inputs(checked_run(['git', '-C', str(source), 'show', f'{parent}:{name}']).stdout)
    differing = sorted(path for path in inputs if _object(source, parent, path) != _object(source, head, path))
    assert not differing, 'Media source changes compiler, SDK or GPU inputs: ' + ', '.join(differing)
    assert _closures(producer) == _closures(source), 'Media source changes a selected SDK or GPU script closure'
    review = {'profile': 'media-only-source-delta', 'GPU_source_revision': parent, 'Media_source_revision': head,
              'changed_paths': changed, 'upstream_inputs_compared': len(inputs),
              'full_registry_mutations': full['actual_full_registry_mutations'], 'all_preflight_groups': 42,
              'compiler_SDK_and_GPU_inputs_preserved': True, 'cache_hits_claimed': False, 'scope': __doc__}
    return source, head, proof_path.resolve(strict=True), review
