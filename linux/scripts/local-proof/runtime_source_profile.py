"""Select one reviewed runtime repair with its own complete source proof; no image, licence, inference or FINAL acceptance."""

from __future__ import annotations

from pathlib import Path
from typing import TYPE_CHECKING

from native_oci_layout import sha
from normal_stage_launch import full_source

if TYPE_CHECKING:
    from proof_types import Json

ANDROID_REVISION = '8c4e13b01fb43f8f55e5ca39aa7c0109d23504e5'
RUNTIME_REVISION = '74f6be54ae463c1e1138a36e740e4f20838d1912'


def select_runtime_source(invocation: Json, selected: Path | None, proof_path: Path | None) -> tuple[Path, Json | None]:
    producer = Path(invocation['source'])
    if selected is None:
        assert proof_path is None, 'Alternate runtime proof requires its selected source'
        return producer, None
    assert proof_path is not None, 'Alternate runtime source requires its complete source proof'
    source = selected.resolve(strict=True)
    assert source != producer.resolve(strict=True), 'Alternate runtime source must be distinct'
    assert invocation['source_revision'] == ANDROID_REVISION, 'Runtime repair requires the reviewed original Android source'
    assert invocation['stage'] == 'android' and invocation['variant'] == 'rocm' and invocation['target_arch'] == 'amd64', 'Reviewed Android lane required'
    proof_path = proof_path.resolve(strict=True)
    complete = full_source(source, proof_path, RUNTIME_REVISION)
    review = {'profile': 'stable-wheel-context-without-smoke-import', 'Android_source_revision': invocation['source_revision'],
              'runtime_source_revision': RUNTIME_REVISION, 'runtime_full_source_proof': str(proof_path),
              'runtime_full_source_proof_sha256': sha(proof_path),
              'full_registry_mutations': complete['actual_full_registry_mutations'],
              'all_preflight_groups': complete['actual_preflight_group_count'],
              'parent_source_and_native_ancestry_preserved': True, 'cache_hits_claimed': False, 'scope': __doc__}
    return source, review
