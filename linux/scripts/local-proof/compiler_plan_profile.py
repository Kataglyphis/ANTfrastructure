"""Constrain reviewed compiler-input deltas; file/history checks do not authenticate receipts or prove cache hits or images."""

from __future__ import annotations

import hashlib
import subprocess
from typing import TYPE_CHECKING, TypedDict

from native_oci_layout import sha

if TYPE_CHECKING:
    from collections.abc import Mapping
    from pathlib import Path

    from proof_types import Json

PROFILES = ('clang-wrapper-repair', 'native-amdgpu')
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
    if profile == 'clang-wrapper-repair':
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
    expected = LLVM_INPUTS | ({TRANSPORT} if profile == 'native-amdgpu' else set())
    assert set(differences) == expected, 'Compiler inputs differ from the reviewed profile'
    if profile == 'native-amdgpu':
        assert transport is not None, 'Native AMDGPU planning requires reviewed OCI transport'
        entry = differences[TRANSPORT]
        assert entry['previous']['sha256'] == LEGACY_TRANSPORT_SHA, 'Unexpected OCI input baseline'
        assert entry['current'] == {'sha256': transport['sha256'], 'size': transport['size']}, 'OCI input fingerprint differs'
