"""Constrain reviewed compiler-input deltas; file/history checks do not authenticate receipts or prove cache hits or images."""

from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path
from typing import TYPE_CHECKING, TypedDict

import compiler_unique_profile as unique
from native_oci_layout import sha
from proof_profiles import TARGETED_STATUSES

if TYPE_CHECKING:
    from collections.abc import Mapping

    from proof_types import Json

PROFILES = ('clang-wrapper-repair', 'native-amdgpu', unique.NAME)
TRANSPORT = 'linux/scripts/01-core/context-management.sh'
TRANSPORT_COMMIT = '8271db71f46ab74393ff45c14864d0eaca6707a5'
LEGACY_TRANSPORT_SHA = '10ff1924998a38a0f0f47f1ace4f7d86661fc028d87c4de900ba1fae0d3b4df1'
CONTROLS = {TRANSPORT, 'linux/scripts/build-cross-stage.sh', 'linux/scripts/lib-orchestrator.sh',
            'linux/scripts/01-core/cross-stage-build.sh', 'linux/scripts/01-core/chain-storage.sh'}
LLVM_INPUTS = {'linux/scripts/02-toolchain/llvm.sh', 'linux/scripts/02-toolchain/llvm-cross.sh',
               'linux/scripts/02-toolchain/materialize-llvm-target.sh'}


class TransportReview(TypedDict):
    commit: str
    sha256: str
    size: int


def reviewed_transport(source: Path, profile: str) -> TransportReview | None:
    assert profile in PROFILES, 'Unknown compiler plan profile'
    if profile in ('clang-wrapper-repair', unique.NAME):
        return None
    subprocess.check_output(['git', '-C', str(source), 'merge-base', '--is-ancestor', TRANSPORT_COMMIT, 'HEAD'], timeout=60)
    expected = subprocess.check_output(['git', '-C', str(source), 'show', TRANSPORT_COMMIT + ':' + TRANSPORT], timeout=60)
    assert (source / TRANSPORT).read_bytes() == expected, 'OCI transport differs from the reviewed commit'
    return {'commit': TRANSPORT_COMMIT, 'sha256': hashlib.sha256(expected).hexdigest(), 'size': len(expected)}


def storage_changes(source: Path, previous: Mapping[str, str], transport: TransportReview | None) -> Json:
    assert set(previous) == CONTROLS, 'Storage audit requires exactly all five controls'
    changes = {name: {'previous': expected, 'current': sha(source / name)}
               for name, expected in previous.items() if sha(source / name) != expected}
    if changes:
        assert transport is not None and set(changes) == {TRANSPORT}, 'Unreviewed storage-control change'
        assert changes[TRANSPORT] == {'previous': LEGACY_TRANSPORT_SHA, 'current': transport['sha256']}, 'Unexpected OCI control baseline'
    return changes


def validate_input_changes(differences: Json, profile: str, transport: TransportReview | None) -> None:
    assert profile in PROFILES, 'Unknown compiler plan profile'
    if profile == unique.NAME:
        unique.validate_changes(differences)
        return
    expected = LLVM_INPUTS | ({TRANSPORT} if profile == 'native-amdgpu' else set())
    assert set(differences) == expected, 'Compiler inputs differ from the reviewed profile'
    if profile == 'native-amdgpu':
        assert transport is not None, 'Native AMDGPU planning requires reviewed OCI transport'
        entry = differences[TRANSPORT]
        assert entry['previous']['sha256'] == LEGACY_TRANSPORT_SHA, 'Unexpected OCI input baseline'
        assert entry['current'] == {'sha256': transport['sha256'], 'size': transport['size']}, 'OCI input fingerprint differs'


def input_reference(source: Path, head: str, template: Path, previous: Json, profile: str) -> Json:
    """Keep historical references separate from the exact compiler6 baseline."""
    assert profile in PROFILES, 'Unknown compiler plan profile'
    if profile == unique.NAME:
        unique.require_source(source, head)
        return unique.reference_inputs(template, previous)
    return json.loads(Path(previous['expensive_inputs_proof']).read_text())['unchanged_bind_files']


def reviewed_dockerfile(source: Path, previous: Path, profile: str) -> Json:
    """Retain old Dockerfile equality or the one reviewed new LLVM bind."""
    assert profile in PROFILES, 'Unknown compiler plan profile'
    materializer = 'linux/scripts/02-toolchain/materialize-llvm-target.sh'
    commit = unique.REPAIR_REVISION if profile == unique.NAME else 'e7ca4436dbb5e58d8f9e0fb49105b6d3b636e9e9'
    accepted = subprocess.check_output(['git','-C',str(source),'show',commit + ':' + materializer],timeout=60)
    assert (source / materializer).read_bytes() == accepted, 'Materializer differs from its reviewed compiler repair'
    current = source / unique.DOCKERFILE
    expected = unique.expected_dockerfile(previous) if profile == unique.NAME else (previous / unique.DOCKERFILE).read_text()
    assert current.read_text() == expected, 'Compiler Dockerfile differs from its reviewed profile'
    if profile == unique.NAME:
        return {'Dockerfile_sha256':sha(current), 'reviewed_Dockerfile_change':'one readonly LLVM GNU_UNIQUE companion bind'}
    return {'identical_Dockerfile_sha256':sha(current)}


def validate_patch_binding(source: Path, head: str, profile: str, targeted: Json, commit: Json) -> None:
    """Require the exact targeted patch and unchanged normal hook policy for each source."""
    assert profile in PROFILES, 'Unknown compiler plan profile'
    key = 'operational-tools' if profile == unique.NAME else 'native-clang-wrappers'
    assert targeted['status'] == TARGETED_STATUSES[key]
    assert targeted['owner_source'] == str(source) and targeted['quality_group_count'] == 26
    assert targeted['cleanup_exit_status'] == targeted['independent_engine_query_exit_status'] == 0 and targeted['owned_container_absent']
    assert commit['head'] == head and commit['source'] == str(source)
    assert commit['status'] == 'passed-local-source-commit-normal-hooks-only' and commit['normal_hook_status'] == 0
    required_hooks = 16
    if profile == unique.NAME:
        unique.require_source(source, head)
        required_hooks = unique.hook_count(source)
    assert commit['actual_hook_mutations'] == required_hooks and commit['clean'] and commit['exact_committed_patch_match']
    assert commit['patch_sha256'] == targeted['patch_sha256']
