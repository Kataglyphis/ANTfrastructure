"""Bind ordinary ROCm Android to its actual Media parent; no authenticated receipt, factory, licence or FINAL acceptance."""

from __future__ import annotations

from pathlib import Path
from typing import TYPE_CHECKING

from gpu_handoff_profile import actual_image
from media_handoff_profile import load_media, media_layout
from native_oci_seed import ANDROID_STATUS as STATUS
from stage_handoff_profile import (
    load_stage_parent,
    native_stage_layout,
    validate_inherited_source,
)

if TYPE_CHECKING:
    from proof_types import Json


def validate_android(invocation: Json, parent: Json, media: Json) -> None:
    assert invocation['stage'] == 'android' and invocation['variant'] == 'rocm', 'Only ordinary ROCm Android is reviewed'
    validate_inherited_source(invocation, parent, media, 'android', 'Media', 'GPU')


def load_android(plan_path: Path, invocation_path: Path) -> tuple[Json, Json, Json]:
    plan, invocation, parent, media = load_stage_parent(plan_path, invocation_path, 'Android', 'Media', load_media, media_layout)
    validate_android(invocation, parent, media)
    return plan, invocation, parent


def android_layout(proof_path: Path, invocation_path: Path, invocation: Json, parent: Json) -> tuple[Json, Path]:
    return native_stage_layout(proof_path, invocation_path, invocation, parent, 'Android', 'Media', STATUS, actual_image)
