"""Bind default Linux Media and Android to their same-target native parents; no factory or FINAL acceptance."""

from __future__ import annotations

import json
import re
from functools import partial
from itertools import pairwise
from pathlib import Path
from typing import TYPE_CHECKING

from default_media_launch import sdk_media_parent
from gpu_handoff_profile import actual_image
from media_handoff_profile import validate_wasm_modes
from native_oci_seed import default_status
from normal_stage_launch import downstream_record, launch_build, stage_inputs
from proof_subject import SDK_TARGETS
from stage_handoff_profile import (
    load_stage_parent,
    native_stage_layout,
    stage_parent,
    validate_source_fields,
)
from webgpu_media_lanes import media_inputs

if TYPE_CHECKING:
    from proof_types import Json


def default_image_config(config: Json, arch: str) -> None:
    environment = config['config']['Env']
    for key, expected in {
        'TARGET_ARCH': arch, 'TARGETARCH': arch, 'BUILD_MODE': 'cross', 'BUILDPLATFORM': 'linux/amd64',
        'ENABLE_AMD': 'false', 'ENABLE_NVIDIA': 'false',
    }.items():
        assert [row for row in environment if row.startswith(key + '=')] == [key + '=' + expected], (
            'Default cross image environment differs: ' + key)


def default_android_inputs(source: Path, output: Path, repo: str, arch: str, context: Path,
                           reference: str) -> tuple[str, list[str], list[str]]:
    image, environment, driver = stage_inputs(source, output, repo, 'android', arch, context, reference, '')
    environment += ['CROSS_VARIANT=', 'CROSS_BUILD_PLATFORM=linux/amd64', 'ENABLE_AMD=false', 'ENABLE_NVIDIA=false']
    return image, environment, driver


def default_reference(image: str, parent: Json) -> str:
    return image.rsplit(':', 1)[0] + '@' + parent['manifest']


def default_unit(unit: str, stage: str, arch: str) -> None:
    assert arch in SDK_TARGETS and re.fullmatch(rf'webgpu-normal-{stage}-default-{arch}-[0-9-]+\.service', unit), (
        f'Unexpected default {stage} unit or target')


def validate_default_stage(invocation: Json, parent: Json, previous: Json, stage: str) -> None:
    arch = invocation['target_arch']
    default_unit(invocation['unit'], stage, arch)
    assert invocation['variant'] == 'default' and invocation['stage'] == stage, 'Default stage scope differs'
    assert invocation['launch_status'] == 0 and invocation['publication'] is False, 'Successful unpublished default launch required'
    assert invocation['source_full_preflight_passed'] and invocation['producer_source_unchanged'], 'Default source proof was not retained'
    validate_source_fields(invocation, previous)
    for field in ('manifest', 'config', 'index_sha256'):
        key = 'parent_OCI_index_sha256' if field == 'index_sha256' else 'parent_' + field
        assert invocation[key] == parent[field], 'Default parent identity differs'


def validate_default_command(invocation: Json, parent: Json, previous: Json, stage: str) -> None:
    arch = invocation['target_arch']
    assert previous['target_arch'] == arch, 'Default parent target differs'
    source, output, context = Path(invocation['source']), Path(invocation['output']), Path(parent['context'])
    repo = invocation['image'].rsplit(':', 1)[0]
    assert re.fullmatch(r'ant-local/webgpu-[a-z0-9][a-z0-9._/-]*', repo), 'Local default candidate repository required'
    reference = default_reference(previous['image'], parent)
    if stage == 'media':
        selected = media_inputs(source, output, repo, 'default', arch, 'sdk', context, reference)
        image, environment, driver = selected['image'], selected['environment'], selected['driver']
    else:
        image, environment, driver = default_android_inputs(source, output, repo, arch, context, reference)
    command = invocation['command']
    assert invocation['image'] == image and command[-len(driver):] == driver, 'Default stage driver or image differs'
    assert command[:2] == ['systemd-run', '--user'] and '--expand-environment=no' in command, 'Default stage transport differs'
    assert [value for value in command if value.startswith('--unit=')] == ['--unit=' + invocation['unit']], 'Default stage command unit differs'
    for expected in environment:
        prefix = expected.partition('=')[0] + '='
        selected_values = [value for option, value in pairwise(command) if option == '-E' and value.startswith(prefix)]
        assert selected_values == [expected], 'Default environment binding differs: ' + prefix


def load_default_media(plan_path: Path, invocation_path: Path) -> tuple[Json, Json, Json]:
    invocation = json.loads(invocation_path.read_text())
    sdk_path, proof_path = stage_parent(invocation, invocation_path, 'Media', 'SDK')
    plan, sdk, parent, _ = sdk_media_parent(plan_path, sdk_path, proof_path, arch=invocation['target_arch'])
    validate_default_stage(invocation, parent, sdk, 'media')
    validate_default_command(invocation, parent, sdk, 'media')
    assert invocation['parent_kind'] == 'SDK' and invocation['SDK_layers_rehashed'] == parent['layers'], 'Default Media SDK coverage differs'
    assert invocation['compiler_layers_matched'] == parent['matched_compiler_layers_and_diffIDs'], 'Default Media compiler coverage differs'
    validate_wasm_modes(invocation)
    return plan, invocation, parent


def default_layout(proof_path: Path, invocation_path: Path, invocation: Json, parent: Json,
                   stage: str, parent_kind: str) -> tuple[Json, Path]:
    arch = invocation['target_arch']
    return native_stage_layout(proof_path, invocation_path, invocation, parent, stage.capitalize(), parent_kind,
                               default_status(stage, arch), actual_image, validate_config=partial(default_image_config, arch=arch))


def default_media_layout(proof_path: Path, invocation_path: Path, invocation: Json, parent: Json) -> tuple[Json, Path]:
    return default_layout(proof_path, invocation_path, invocation, parent, 'media', 'SDK')


def default_android_layout(proof_path: Path, invocation_path: Path, invocation: Json, parent: Json) -> tuple[Json, Path]:
    return default_layout(proof_path, invocation_path, invocation, parent, 'android', 'Media')


def load_default_android(plan_path: Path, invocation_path: Path) -> tuple[Json, Json, Json]:
    plan, invocation, parent, media = load_stage_parent(plan_path, invocation_path, 'Android', 'Media',
                                                        load_default_media, default_media_layout)
    validate_default_stage(invocation, parent, media, 'android')
    validate_default_command(invocation, parent, media, 'android')
    assert invocation['Media_layers_rehashed'] == parent['layers'], 'Default Android Media coverage differs'
    assert invocation['SDK_layers_matched'] == parent['matched_SDK_layers_and_diffIDs'], 'Default Android SDK coverage differs'
    return plan, invocation, parent


def launch_default_android(plan_path: Path, invocation_path: Path, proof_path: Path, output: Path, unit: str, repo: str) -> int:
    plan, invocation, sdk = load_default_media(plan_path, invocation_path)
    arch = invocation['target_arch']
    default_unit(unit, 'android', arch)
    assert re.fullmatch(r'ant-local/webgpu-[a-z0-9][a-z0-9._/-]*', repo), 'Local default candidate repository required'
    parent, context = default_media_layout(proof_path, invocation_path, invocation, sdk)
    source = Path(invocation['source'])
    image, environment, driver = default_android_inputs(source, output, repo, arch, context, default_reference(invocation['image'], parent))
    record = downstream_record(invocation, invocation_path, proof_path, parent, 'Media')
    record.update(stage='android', variant='default', Media_layers_rehashed=parent['layers'],
                  SDK_layers_matched=sdk['layers'], scope=__doc__, GPU_or_FINAL_acceptance=False)
    return launch_build(source, output, unit, image, arch, plan['required_bytes'], record, environment, driver)
