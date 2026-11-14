"""Constrain the HIP output-format repair when reusing a qualified SDK; no provenance, build or inference acceptance."""

from __future__ import annotations

from pathlib import Path
from typing import TYPE_CHECKING

from normal_stage_launch import full_source
from proof_commands import checked_run

if TYPE_CHECKING:
    from proof_types import Json

SDK_REVISION = '652e5440c9cbbecee486ff86dab873b9ace967ec'
TOOL_BASE = '175a56af51308679fd084dc91dae621ba0c85b4c'
HIP = 'linux/scripts/03-media/build/migraphx/check-hip-compiler.sh'
HOST_BASE_CHANGES = {
    'linux/scripts/03-media/build/migraphx/source-check.sh',
    'linux/scripts/local-proof/buildcache_transfer.py',
    'linux/scripts/local-proof/compiler_plan_profile.py',
    'linux/scripts/local-proof/inventory.json',
    'linux/scripts/local-proof/prepare-next-compiler-plan.py',
    'linux/scripts/local-proof/seed-buildkit-cache.py',
}
REPAIR_CHANGES = {HIP, 'linux/scripts/local-proof/launch-normal-gpu.py',
                  'linux/scripts/local-proof/gpu_source_profile.py', 'linux/scripts/local-proof/inventory.json'}
METADATA = {'AGENTS.md', 'README.md', 'CHANGELOG.md', 'docs/code-quality-tooling.md', 'docs/failure-modes.md',
            'docs/local-proof-workflows.md', 'docs/linux-accelerator-images.md', 'docs/scripts/mutations.json'}


def meaningful_paths(paths: list[str]) -> set[str]:
    return {name for name in paths if name not in METADATA and not name.startswith('linux/scripts/tests/')}


def git_paths(source: Path, before: str, after: str) -> set[str]:
    result = checked_run(['git', '-C', str(source), 'diff', '--name-only', before, after])
    return meaningful_paths(result.stdout.splitlines())


def expected_hip_repair(previous: str) -> str:
    changes = [('--cuda-device-only -std=c++17', '--cuda-device-only --no-gpu-bundle-output -std=c++17'),
               ('hip_machine="$(elf_machine_name "$1")" || return',
                'hip_machine="$(elf_machine_name "$1")" || { printf \'HIP probe output is not a readable ELF device object\\n\' >&2; return 1; }')]
    for before, after in changes:
        assert previous.count(before) == 1, 'Unrecognized original HIP check'
        previous = previous.replace(before, after, 1)
    return previous


def select_gpu_source(plan: Json, selected: Path | None, proof_path: Path | None) -> tuple[Path, str, Path, Json | None]:
    producer = Path(plan['source'])
    assert bool(selected) == bool(proof_path), 'Alternate GPU source requires its complete source proof'
    if selected is None:
        return producer, plan['source_revision'], Path(plan['full_source_preflight_proof']), None
    assert proof_path is not None
    source = selected.resolve(strict=True)
    assert source != producer.resolve(strict=True), 'Alternate GPU source must be distinct'
    assert plan['source_revision'] == SDK_REVISION, 'HIP repair requires the reviewed frozen SDK source'
    head = checked_run(['git', '-C', str(source), 'rev-parse', 'HEAD']).stdout.strip()
    checked_run(['git', '-C', str(source), 'merge-base', '--is-ancestor', TOOL_BASE, head])
    assert git_paths(source, SDK_REVISION, TOOL_BASE) == HOST_BASE_CHANGES, 'Unreviewed intervening image inputs'
    assert git_paths(source, TOOL_BASE, head) == REPAIR_CHANGES, 'Unreviewed HIP repair input changes'
    assert (source / HIP).read_text() == expected_hip_repair((producer / HIP).read_text()), 'GPU source contains more than the exact HIP output-format repair'
    for relative in ('linux/Dockerfile.sdk', 'linux/Dockerfile.amd', 'linux/scripts/01-core/versions.env'):
        assert (source / relative).read_bytes() == (producer / relative).read_bytes(), 'SDK/GPU Dockerfile or pins differ'
    full = full_source(source, proof_path, head)
    review = {'profile': 'hip-object-output', 'SDK_source_revision': SDK_REVISION, 'tool_base': TOOL_BASE,
              'GPU_source_revision': head, 'reviewed_changes': sorted(REPAIR_CHANGES),
              'full_registry_mutations': full['actual_full_registry_mutations'], 'all_preflight_groups': 42,
              'compiler_and_SDK_inputs_preserved': True, 'cache_hits_claimed': False, 'scope': __doc__}
    return source, head, proof_path.resolve(strict=True), review
