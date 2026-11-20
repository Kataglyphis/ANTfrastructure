"""Bind ordinary ROCm Media to its real GPU parent; no authenticated receipt, factory, licence or FINAL acceptance."""

from __future__ import annotations

from pathlib import Path
from typing import TYPE_CHECKING

from gpu_handoff_profile import actual_image, gpu_layout, load_gpu
from native_oci_seed import MEDIA_STATUS as STATUS
from stage_handoff_profile import (
    load_stage_parent,
    native_stage_layout,
    validate_inherited_source,
)

if TYPE_CHECKING:
    from proof_types import Json


def validate_media(invocation: Json, parent: Json, gpu: Json) -> None:
    validate_inherited_source(invocation, parent, gpu, 'media', 'GPU', 'SDK')
    assert invocation['ORT_WEB_REQUIRED'] == 1 and invocation['ORT_WASM_WEBGPU_FLAVORS'] is True, 'Both required Media Wasm modes must be retained'
    assert invocation['command'].count('ORT_WEB_REQUIRED=1') == invocation['command'].count('ORT_WASM_WEBGPU_FLAVORS=true') == 1, 'Media Wasm command flags differ'


def load_media(plan_path: Path, invocation_path: Path) -> tuple[Json, Json, Json]:
    plan, invocation, parent, gpu = load_stage_parent(plan_path, invocation_path, 'Media', 'GPU', load_gpu, gpu_layout)
    validate_media(invocation, parent, gpu)
    return plan, invocation, parent


def media_layout(proof_path: Path, invocation_path: Path, invocation: Json, parent: Json) -> tuple[Json, Path]:
    return native_stage_layout(proof_path, invocation_path, invocation, parent, 'Media', 'GPU', STATUS, actual_image)
