"""Constrain reviewed HIP and backend-install repairs when reusing a qualified SDK; no provenance, build or inference acceptance."""

from __future__ import annotations

from pathlib import Path
from typing import TYPE_CHECKING

from native_oci_layout import sha
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
BACKEND_REPAIR_HASHES = {
    'linux/scripts/local-proof/proof_profiles.py': '6dad8cde51f997a3a62f88834c863ec2efeeb1e82046398abee3f233b658a9dc',
    'linux/scripts/03-media/build/migraphx/stage-backend-install.py': '715cea6765ab1fdb9c0ed5a941a8e6b793fd62d2d42ee1305ec557970eef4889',
    'linux/scripts/06-packaging/media-payloads.sh': '1dc5842a269e70474b859473bb91fe5bc963b2bb1f4e87ad99aae6683d7ee784',
    'linux/Dockerfile.amd': '5a5f296d4a7dd30cd85d5624029a8c192b056d7d1ad7322a80feddd2502ea8a8',
    'linux/Dockerfile.package': '71d038133f2c97c6a3d364d28e945dcac03089d2bafd8f57633f6d27813bbe25',
}
RUNTIME_REPAIR_HASHES = {
    **BACKEND_REPAIR_HASHES,
    'linux/scripts/local-proof/proof_profiles.py': 'd1887350ebff052ff8cae43be5d8dced431424279739f3ee643bfcaf6c4e6b5d',
    'linux/scripts/03-media/build/migraphx/stage-backend-install.py': 'fe1e27fdd1ae4e5679c9ec79f63d516d18fde2070063aa9725137cd70131e012',
    'linux/scripts/06-packaging/media-payloads.sh': '1415852c08073e326751d88962ee0b4fa47b74a4ce04b2416fd8e84b1f2a892a',
    'linux/scripts/03-media/build/migraphx/build-image.sh': '63041115561be9f5e7c6276f339fc4ba9c6db564638ff30b696f13578c583955',
}
METADATA = {'AGENTS.md', 'README.md', 'CHANGELOG.md', 'BACKLOG.md', 'docs/code-quality-tooling.md', 'docs/failure-modes.md',
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


def repair_profile(paths: set[str]) -> tuple[str, dict[str, str]]:
    for name, hashes in (('backend-runtime-load', RUNTIME_REPAIR_HASHES), ('backend-install-manifest', BACKEND_REPAIR_HASHES)):
        if paths == REPAIR_CHANGES | hashes.keys():
            return name, hashes
    assert paths == REPAIR_CHANGES, 'Unreviewed HIP repair input changes'
    return 'hip-object-output', {}


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
    paths = git_paths(source, TOOL_BASE, head)
    profile, hashes = repair_profile(paths)
    assert (source / HIP).read_text() == expected_hip_repair((producer / HIP).read_text()), 'GPU source contains more than the exact HIP output-format repair'
    for relative in ('linux/Dockerfile.sdk', 'linux/scripts/01-core/versions.env', *(() if hashes else ('linux/Dockerfile.amd',))):
        assert (source / relative).read_bytes() == (producer / relative).read_bytes(), 'SDK/GPU Dockerfile or pins differ'
    for relative, expected in hashes.items():
        assert sha(source / relative) == expected, 'Backend install repair bytes differ: ' + relative
    full = full_source(source, proof_path, head)
    review = {'profile': profile, 'SDK_source_revision': SDK_REVISION, 'tool_base': TOOL_BASE,
              'GPU_source_revision': head, 'reviewed_changes': sorted(paths),
              'full_registry_mutations': full['actual_full_registry_mutations'], 'all_preflight_groups': 42,
              'compiler_and_SDK_inputs_preserved': True, 'cache_hits_claimed': False, 'scope': __doc__}
    return source, head, proof_path.resolve(strict=True), review
