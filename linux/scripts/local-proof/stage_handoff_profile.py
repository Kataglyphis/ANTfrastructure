"""Share exact native stage/parent bindings; supplied receipts do not authenticate source, ABI, licence or GPU acceptance."""

from __future__ import annotations

import json
from itertools import pairwise
from pathlib import Path
from typing import TYPE_CHECKING

from native_oci_layout import layer_ancestry, sha
from native_oci_seed import parent_layout
from normal_stage_launch import validate_stage_invocation

if TYPE_CHECKING:
    from collections.abc import Callable

    from proof_types import Json


def stage_parent_reference(image: str, parent: Json) -> str:
    return image.rsplit(':', 1)[0] + '@' + parent['manifest']


def validate_baked_environment(config: Json, expected_values: dict[str, str], profile: str) -> None:
    environment = config['config']['Env']
    for key, value in expected_values.items():
        assert [entry for entry in environment if entry.startswith(key + '=')] == [key + '=' + value], (
            profile + ' cross image environment differs: ' + key)


def validate_profile_stage(invocation: Json, parent: Json, stage: str, variant: str) -> None:
    assert invocation['variant'] == variant and invocation['stage'] == stage, 'Stage profile scope differs'
    assert invocation['launch_status'] == 0 and invocation['publication'] is False, 'Successful unpublished stage launch required'
    assert invocation['source_full_preflight_passed'] and invocation['producer_source_unchanged'], 'Stage source proof was not retained'
    for field in ('manifest', 'config'):
        assert invocation['parent_' + field] == parent[field], 'Stage parent identity differs'
    assert invocation['parent_OCI_index_sha256'] == parent['index_sha256'], 'Stage parent index differs'


def validate_profile_command(invocation: Json, image: str, environment: list[str], driver: list[str]) -> None:
    command = invocation['command']
    assert invocation['image'] == image and command[-len(driver):] == driver, 'Stage driver or image differs'
    assert command[:2] == ['systemd-run', '--user'] and '--expand-environment=no' in command, 'Stage transport differs'
    assert [value for value in command if value.startswith('--unit=')] == ['--unit=' + invocation['unit']], 'Stage command unit differs'
    for expected in environment:
        prefix = expected.partition('=')[0] + '='
        selected_values = [value for option, value in pairwise(command) if option == '-E' and value.startswith(prefix)]
        assert selected_values == [expected], 'Stage environment binding differs: ' + prefix


def validate_inherited_source(invocation: Json, parent: Json, previous: Json,
                              stage: str, parent_kind: str, ancestor_kind: str) -> None:
    validate_stage_invocation(invocation, parent, stage, previous['image'])
    validate_source_fields(invocation, previous)
    assert invocation[parent_kind + '_layers_rehashed'] == parent['layers'], 'Downstream parent layer coverage differs'
    assert invocation[ancestor_kind + '_layers_matched'] == parent['matched_' + ancestor_kind + '_layers_and_diffIDs'], 'Downstream ancestry differs'


def validate_source_fields(invocation: Json, previous: Json) -> None:
    for field in ('source', 'source_revision', 'source_full_preflight_proof', 'source_full_preflight_sha256'):
        assert invocation[field] == previous[field], 'Downstream must retain its exact proven parent source'
    assert invocation['parent_source_revision'] == previous['source_revision'], 'Downstream parent source differs'


def stage_parent(invocation: Json, invocation_path: Path, kind: str, parent_kind: str) -> tuple[Path, Path]:
    assert Path(invocation['output']) == invocation_path.resolve().parent, f'{kind} output binding differs'
    parent_path, proof_path = Path(invocation[parent_kind + '_invocation']), Path(invocation['parent_OCI_proof'])
    assert sha(parent_path) == invocation[parent_kind + '_invocation_sha256'] and sha(proof_path) == invocation['parent_OCI_proof_sha256'], f'{kind} parent receipt bytes changed'
    return parent_path, proof_path


def load_stage_parent(plan_path: Path, invocation_path: Path, kind: str, parent_kind: str,
                      loader: Callable[[Path, Path], tuple[Json, Json, Json]],
                      layout: Callable[[Path, Path, Json, Json], tuple[Json, Path]]) -> tuple[Json, Json, Json, Json]:
    invocation = json.loads(invocation_path.read_text())
    parent_path, proof_path = stage_parent(invocation, invocation_path, kind, parent_kind)
    plan, previous, ancestor = loader(plan_path, parent_path)
    parent, _ = layout(proof_path, parent_path, previous, ancestor)
    return plan, invocation, parent, previous


def native_stage_layout(proof_path: Path, invocation_path: Path, invocation: Json, parent: Json,
                        kind: str, parent_kind: str, status: str,
                        engine_image: Callable[[Json], Json], *,
                        validate_config: Callable[[Json], None] | None = None) -> tuple[Json, Path]:
    proof, context, native = parent_layout(proof_path)
    assert proof['status'] == status and proof[kind + '_invocation'] == str(invocation_path.resolve()), f'{kind} OCI proof scope differs'
    assert proof[kind + '_invocation_sha256'] == sha(invocation_path), f'{kind} invocation bytes changed'
    assert proof['source_revision'] == invocation['source_revision'], f'{kind} OCI source differs'
    assert proof['parent_OCI_proof_sha256'] == invocation['parent_OCI_proof_sha256'], f'{kind} OCI {parent_kind} proof differs'
    assert proof['export_transport'] == {'producer_status': 0, 'extractor_status': 0} and proof['parent_layer_reuse_verified'], f'{kind} export transport failed'
    _, _, ancestor = parent_layout(Path(invocation['parent_OCI_proof']))
    assert proof['matched_' + parent_kind + '_layers_and_diffIDs'] == parent['layers'], f'{kind} {parent_kind} coverage differs'
    layer_ancestry(native, ancestor, parent['layers'])
    if validate_config is not None:
        validate_config(native[2])
    actual = engine_image(invocation)
    assert proof['manifest'] == actual['manifest'] and proof['config'] == actual['config'], f'Engine {kind} image differs'
    return proof, context
