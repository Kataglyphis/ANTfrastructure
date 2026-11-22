"""Bind ordinary NVIDIA GPU and Media to the selected Linux cross target and native OCI parent."""

from __future__ import annotations

import json
import re
from functools import partial
from pathlib import Path
from typing import TYPE_CHECKING

from default_media_launch import sdk_media_parent
from gpu_handoff_profile import actual_image
from media_handoff_profile import validate_wasm_modes
from native_oci_seed import NVIDIA_GPU_STATUSES, NVIDIA_MEDIA_STATUSES
from normal_stage_launch import MEDIA_REQUIRED_BYTES, downstream_record, launch_build, stage_inputs
from stage_handoff_profile import (
    load_stage_parent,
    native_stage_layout,
    stage_parent,
    stage_parent_reference,
    validate_baked_environment,
    validate_profile_command,
    validate_profile_stage,
    validate_source_fields,
)
from webgpu_media_lanes import media_inputs

if TYPE_CHECKING:
    from proof_types import Json

NVIDIA_TARGETS = tuple(NVIDIA_GPU_STATUSES)
LOCAL_REPO = r'ant-local/webgpu-[a-z0-9][a-z0-9._/-]*'


def nvidia_unit(unit: str, stage: str, arch: str) -> None:
    assert arch in NVIDIA_TARGETS and re.fullmatch(rf'webgpu-normal-{stage}-nvidia-{arch}-[0-9-]+\.service', unit), (
        f'Unexpected NVIDIA {stage} unit or target')


def nvidia_image_config(config: Json, arch: str, *, media: bool = False) -> None:
    expected = {
        'TARGET_ARCH': arch, 'TARGETARCH': arch, 'BUILD_MODE': 'cross', 'BUILDPLATFORM': 'linux/amd64',
        'CUDA_HOME': '/usr/local/cuda', 'TENSORRT_HOME': '/usr/local/tensorrt',
    }
    if media:
        expected.update(ENABLE_AMD='false', ENABLE_NVIDIA='true', ENABLE_TENSORRT='true')
    validate_baked_environment(config, expected, 'NVIDIA')


def nvidia_inputs(source: Path, output: Path, repo: str, stage: str, arch: str, context: Path,
                  reference: str) -> tuple[str, list[str], list[str]]:
    assert (stage in {'gpu', 'media'} and arch in NVIDIA_TARGETS), 'Unreviewed NVIDIA lane'
    assert re.fullmatch(LOCAL_REPO, repo) and all(path.is_absolute() for path in (source, output, context)), 'Local NVIDIA stage paths or repository differ'
    assert re.fullmatch(LOCAL_REPO + r'@sha256:[0-9a-f]{64}', reference), 'Immutable local NVIDIA parent required'
    if stage == 'media':
        selected = media_inputs(source, output, repo, 'nvidia', arch, 'gpu', context, reference)
        image, environment, driver = selected['image'], selected['environment'], selected['driver']
    else:
        image, environment, driver = stage_inputs(source, output, repo, 'gpu', arch, context, reference, 'nvidia')
        environment += ['CROSS_BUILD_PLATFORM=linux/amd64', 'ENABLE_NVIDIA=true', 'ENABLE_AMD=false', 'CUDA_INSTALL_COMPAT=1']
        if arch == 'arm64':
            environment.append('CROSS_NVIDIA_SBSA=1')
    if arch == 'amd64':
        environment.append('CROSS_NVIDIA_SBSA=0')
    deepstream = 'true' if arch == 'amd64' else 'false'
    environment += ['ENABLE_TENSORRT=true', 'ENABLE_DEEPSTREAM=' + deepstream, 'CROSS_IMAGE_PRUNE=0', 'PRUNE_DUP_CACHEMOUNTS=0']
    return image, environment, driver


def validate_nvidia_stage(invocation: Json, parent: Json, previous: Json, stage: str, context: Path) -> None:
    arch = invocation['target_arch']
    nvidia_unit(invocation['unit'], stage, arch)
    assert previous['target_arch'] == arch, 'NVIDIA parent target differs'
    validate_profile_stage(invocation, parent, stage, 'nvidia')
    validate_source_fields(invocation, previous)
    repository = invocation['image'].rsplit(':', 1)[0].removesuffix('-stages')
    paths = Path(invocation['source']), Path(invocation['output'])
    reference = stage_parent_reference(previous['image'], parent)
    validate_profile_command(invocation, *nvidia_inputs(*paths, repository, stage, arch, context, reference))


def load_nvidia_gpu(plan_path: Path, invocation_path: Path) -> tuple[Json, Json, Json]:
    invocation = json.loads(invocation_path.read_text())
    arch = invocation['target_arch']
    sdk_path, proof_path = stage_parent(invocation, invocation_path, 'GPU', 'SDK')
    plan, sdk, parent, context = sdk_media_parent(plan_path, sdk_path, proof_path, arch=arch)
    validate_nvidia_stage(invocation, parent, sdk, 'gpu', context)
    assert invocation['SDK_layers_rehashed'] == parent['layers'], 'NVIDIA GPU SDK coverage differs'
    assert invocation['compiler_layers_rehashed'] == parent['matched_compiler_layers_and_diffIDs'], 'NVIDIA compiler coverage differs'
    return plan, invocation, parent


def nvidia_gpu_layout(proof_path: Path, invocation_path: Path, invocation: Json, parent: Json) -> tuple[Json, Path]:
    arch = invocation['target_arch']
    return native_stage_layout(proof_path, invocation_path, invocation, parent, 'GPU', 'SDK',
                               NVIDIA_GPU_STATUSES[arch], actual_image, validate_config=partial(nvidia_image_config, arch=arch))


def load_nvidia_media(plan_path: Path, invocation_path: Path) -> tuple[Json, Json, Json]:
    plan, invocation, parent, gpu = load_stage_parent(plan_path, invocation_path, 'Media', 'GPU',
                                                      load_nvidia_gpu, nvidia_gpu_layout)
    validate_nvidia_stage(invocation, parent, gpu, 'media', Path(parent['context']))
    assert invocation['GPU_layers_rehashed'] == parent['layers'], 'NVIDIA Media GPU coverage differs'
    assert invocation['SDK_layers_matched'] == parent['matched_SDK_layers_and_diffIDs'], 'NVIDIA Media SDK coverage differs'
    validate_wasm_modes(invocation)
    return plan, invocation, parent


def nvidia_media_layout(proof_path: Path, invocation_path: Path, invocation: Json, parent: Json) -> tuple[Json, Path]:
    arch = invocation['target_arch']
    return native_stage_layout(proof_path, invocation_path, invocation, parent, 'Media', 'GPU',
                               NVIDIA_MEDIA_STATUSES[arch], actual_image,
                               validate_config=partial(nvidia_image_config, arch=arch, media=True))


def launch_nvidia_gpu(plan_path: Path, sdk_path: Path, proof_path: Path, output: Path, unit: str, repo: str, arch: str) -> int:
    nvidia_unit(unit, 'gpu', arch)
    plan, sdk, parent, context = sdk_media_parent(plan_path, sdk_path, proof_path, arch=arch)
    source = Path(sdk['source'])
    image, environment, driver = nvidia_inputs(source, output, repo, 'gpu', arch, context, stage_parent_reference(sdk['image'], parent))
    record = downstream_record(sdk, sdk_path, proof_path, parent, 'SDK')
    record.update(stage='gpu', variant='nvidia', SDK_layers_rehashed=parent['layers'],
                  compiler_layers_rehashed=parent['matched_compiler_layers_and_diffIDs'], GPU_or_FINAL_acceptance=False, scope=__doc__)
    return launch_build(source, output, unit, image, arch, plan['required_bytes'], record, environment, driver)


def launch_nvidia_media(plan_path: Path, invocation_path: Path, proof_path: Path, output: Path, unit: str, repo: str) -> int:
    plan, gpu, sdk = load_nvidia_gpu(plan_path, invocation_path)
    arch = gpu['target_arch']
    nvidia_unit(unit, 'media', arch)
    parent, context = nvidia_gpu_layout(proof_path, invocation_path, gpu, sdk)
    source = Path(gpu['source'])
    image, environment, driver = nvidia_inputs(source, output, repo, 'media', arch, context, stage_parent_reference(gpu['image'], parent))
    record = downstream_record(gpu, invocation_path, proof_path, parent, 'GPU')
    record.update(stage='media', variant='nvidia', GPU_layers_rehashed=parent['layers'], SDK_layers_matched=sdk['layers'],
                  ORT_WEB_REQUIRED=1, ORT_WASM_WEBGPU_FLAVORS=True, GPU_or_FINAL_acceptance=False, scope=__doc__)
    return launch_build(source, output, unit, image, arch, max(plan['required_bytes'], MEDIA_REQUIRED_BYTES), record, environment, driver)
