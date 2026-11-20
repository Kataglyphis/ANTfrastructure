"""Review only the exact GNU_UNIQUE compiler lineage; hashes and supplied receipts do not prove builds or cache hits."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import TYPE_CHECKING

from native_oci_layout import sha

if TYPE_CHECKING:
    from proof_types import Json

NAME = 'llvm-gnu-unique'
SOURCE_REVISION = 'a4741df72654abd91008f75ced01f57e7b4a1461'
REFERENCE_REVISION = '652e5440c9cbbecee486ff86dab873b9ace967ec'
REPAIR_REVISION = '60ce0c91e8831fbf1e2886b887a75dafbf4c2910'
ADDED_INPUT = 'linux/scripts/02-toolchain/llvm-gnu-unique.sh'
INPUTS = {
    ADDED_INPUT, 'linux/scripts/01-core/runtime-build-fns.sh',
    'linux/scripts/02-toolchain/build-clang.sh', 'linux/scripts/02-toolchain/llvm-validate.sh',
    'linux/scripts/02-toolchain/llvm-cross.sh', 'linux/scripts/02-toolchain/llvm.sh',
    'linux/scripts/02-toolchain/materialize-llvm-target.sh',
}
FIXTURE_CHANGES = {
    'AGENTS.md', 'BACKLOG.md', 'CHANGELOG.md', 'README.md', 'docs/code-quality-tooling.md',
    'docs/failure-modes.md', 'docs/local-proof-workflows.md', 'docs/scripts/mutations.json',
    'linux/scripts/tests/gpu_source_profile_tests.py',
}
DOCKERFILE = 'linux/Dockerfile.toolchain'
MOUNT_OWNER = 'linux/scripts/02-toolchain/llvm-validate.sh'
MOUNT = '    --mount=type=bind,source=' + ADDED_INPUT + ',target=/opt/scripts/toolchain/llvm-gnu-unique.sh,ro \\\n'


def git(source: Path, *arguments: str) -> bytes:
    """Read the selected local repository without changing its checkout."""
    return subprocess.check_output(['git', '-C', str(source), *arguments], timeout=60)


def require_source(source: Path, head: str) -> None:
    """Bind the exact fixture descendant and unchanged reviewed compiler bytes."""
    assert head == SOURCE_REVISION, 'GNU_UNIQUE requires its exact reviewed source'
    changes = git(source, 'diff', '--name-only', REPAIR_REVISION, head).decode().splitlines()
    assert set(changes) == FIXTURE_CHANGES, 'Unreviewed changes after the compiler repair'
    for name in INPUTS | {DOCKERFILE}:
        expected = git(source, 'show', REPAIR_REVISION + ':' + name)
        assert (source / name).read_bytes() == expected, 'Reviewed compiler repair bytes differ: ' + name


def fingerprint(source: Path, name: str) -> Json:
    """Retain a relative source file's exact byte identity."""
    relative = Path(name)
    assert not relative.is_absolute() and '..' not in relative.parts, 'Input path escapes its source'
    path = source / relative
    return {'sha256': sha(path), 'size': path.stat().st_size}


def reference_inputs(template: Path, previous: Json) -> Json:
    """Recover the compiler6 baseline without rewriting its original input report."""
    source = Path(previous['source'])
    assert previous['source_revision'] == REFERENCE_REVISION, 'GNU_UNIQUE requires the reviewed compiler6 baseline'
    assert git(source, 'rev-parse', 'HEAD').decode().strip() == REFERENCE_REVISION, 'Compiler6 source head differs'
    assert not git(source, 'status', '--porcelain').strip(), 'Compiler6 source is dirty'
    report = json.loads((template.parent / previous['build_inputs_comparison']).read_text())
    assert report['source_revision'] == REFERENCE_REVISION, 'Compiler6 input report source differs'
    unchanged, changed = report['unchanged_bound_files'], report['changed_bound_files']
    assert unchanged and not (unchanged.keys() & changed.keys()), 'Compiler6 input groups overlap or are empty'
    inputs = {**unchanged, **{name: value['current'] for name, value in changed.items()}}
    assert ADDED_INPUT not in inputs and not (source / ADDED_INPUT).exists(), 'New companion already appears in the baseline'
    for name, expected in inputs.items():
        assert fingerprint(source, name) == expected, 'Compiler6 input fingerprint differs: ' + name
    return {**inputs, ADDED_INPUT: None}


def validate_changes(differences: Json) -> None:
    """Refuse missing, extra or misreported companion deltas."""
    assert set(differences) == INPUTS, 'Compiler inputs differ from the reviewed GNU_UNIQUE profile'
    assert differences[ADDED_INPUT]['previous'] is None, 'New companion needs an explicit absent baseline'
    assert all(value['previous'] is not None for name, value in differences.items() if name != ADDED_INPUT), 'Existing compiler input lost its baseline'


def expected_dockerfile(previous: Path) -> str:
    """Permit precisely the narrow companion bind in the existing LLVM RUN."""
    text = (previous / DOCKERFILE).read_text()
    anchor = '    --mount=type=bind,source=' + MOUNT_OWNER + ',target=/opt/scripts/toolchain/llvm-validate.sh,ro \\\n'
    assert text.count(anchor) == 1, 'Unrecognized compiler6 LLVM companion anchor'
    return text.replace(anchor, anchor + MOUNT, 1)


def hook_count(source: Path) -> int:
    """Require every matching normal hook mutation up to the unchanged standard cap."""
    paths = set(git(source, 'diff', '--name-only', 'HEAD^', 'HEAD').decode().splitlines())
    registry = json.loads((source / 'docs/scripts/mutations.json').read_text())
    matched = sum(row['target'] in paths for row in registry)
    assert matched > 0, 'GNU_UNIQUE source commit has no matching normal hook mutations'
    return min(16, matched)
