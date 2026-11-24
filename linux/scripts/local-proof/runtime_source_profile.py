"""Select one reviewed runtime repair with its own complete source proof; no image, licence, inference or FINAL acceptance."""

from __future__ import annotations

from pathlib import Path
from typing import TYPE_CHECKING

from media_source_profile import (
    UPSTREAM_DOCKERFILES,
    _closures,
    changed_inputs,
    descendant_source,
)
from native_oci_layout import sha
from normal_stage_launch import full_source
from proof_commands import checked_run

if TYPE_CHECKING:
    from proof_types import Json

ANDROID_REVISION = '8c4e13b01fb43f8f55e5ca39aa7c0109d23504e5'
RUNTIME_REVISION = '2aa1a7780861db8012cb769e04d3de474dddca37'
ANDROID_DOCKERFILES = (*UPSTREAM_DOCKERFILES, 'linux/Dockerfile.media', 'linux/Dockerfile.android')
# Loaded only through artifact-common.sh by host orchestrators; see docs/local-proof-workflows.md § A runtime source newer than its Android parent
HOST_ONLY_FILES = frozenset({'linux/scripts/01-core/runtime-build-fns.sh'})


def _review(invocation: Json, revision: str, proof_path: Path, complete: Json, profile: str) -> Json:
    return {'profile': profile, 'Android_source_revision': invocation['source_revision'],
            'runtime_source_revision': revision, 'runtime_full_source_proof': str(proof_path),
            'runtime_full_source_proof_sha256': sha(proof_path),
            'full_registry_mutations': complete['actual_full_registry_mutations'],
            'all_preflight_groups': complete['actual_preflight_group_count'],
            'parent_source_and_native_ancestry_preserved': True, 'cache_hits_claimed': False, 'scope': __doc__}


def _host_only_delta(invocation: Json, producer: Path, selected: Path, proof_path: Path) -> tuple[Path, Json]:
    parent = str(invocation['source_revision'])
    source, head, complete, changed = descendant_source(producer, selected, proof_path, parent)
    _, differing = changed_inputs(source, parent, head, ANDROID_DOCKERFILES)
    touched = set(filter(None, checked_run(['git', '-C', str(source), 'diff', '--name-only', parent, head, '--', *differing]).stdout.splitlines())) if differing else set()
    assert touched <= HOST_ONLY_FILES, 'Runtime source changes a base-to-Android image input: ' + ', '.join(sorted(touched - HOST_ONLY_FILES))
    for name in ANDROID_DOCKERFILES:
        text = checked_run(['git', '-C', str(source), 'show', f'{head}:{name}']).stdout
        assert not any(Path(path).name in text for path in HOST_ONLY_FILES), 'An image stage names a host-only runtime file: ' + name
    assert _closures(producer) == _closures(source), 'Runtime source changes a selected SDK or GPU script closure'
    review = _review(invocation, head, proof_path, complete, 'host-only-runtime-delta')
    review.update(changed_paths=changed, host_only_inputs_changed=sorted(touched))
    return source, review


def select_runtime_source(invocation: Json, selected: Path | None, proof_path: Path | None) -> tuple[Path, Json | None]:
    producer = Path(invocation['source'])
    if selected is None:
        assert proof_path is None, 'Alternate runtime proof requires its selected source'
        return producer, None
    assert proof_path is not None, 'Alternate runtime source requires its complete source proof'
    source = selected.resolve(strict=True)
    assert source != producer.resolve(strict=True), 'Alternate runtime source must be distinct'
    assert invocation['stage'] == 'android' and invocation['variant'] == 'rocm' and invocation['target_arch'] == 'amd64', 'Reviewed Android lane required'
    proof_path = proof_path.resolve(strict=True)
    if invocation['source_revision'] != ANDROID_REVISION:
        return _host_only_delta(invocation, producer.resolve(strict=True), source, proof_path)
    complete = full_source(source, proof_path, RUNTIME_REVISION)
    return source, _review(invocation, RUNTIME_REVISION, proof_path, complete, 'stable-wheel-context-without-smoke-import')
