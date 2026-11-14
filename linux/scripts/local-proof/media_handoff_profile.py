"""Bind ordinary ROCm Media to its real GPU parent; no authenticated receipt, factory, licence or FINAL acceptance."""

from __future__ import annotations

import json
from pathlib import Path
from typing import TYPE_CHECKING

from gpu_handoff_profile import actual_image, gpu_layout, load_gpu
from native_oci_layout import layer_ancestry, sha
from native_oci_seed import MEDIA_STATUS as STATUS
from native_oci_seed import parent_layout
from normal_stage_launch import validate_stage_invocation

if TYPE_CHECKING:
    from proof_types import Json


def validate_media(invocation: Json, parent: Json, gpu: Json) -> None:
    validate_stage_invocation(invocation, parent, 'media', gpu['image'])
    for field in ('source', 'source_revision', 'source_full_preflight_proof', 'source_full_preflight_sha256'):
        assert invocation[field] == gpu[field], 'Media must retain its exact proven GPU source'
    assert invocation['parent_source_revision'] == gpu['source_revision'], 'Media parent source differs'
    assert invocation['GPU_layers_rehashed'] == parent['layers'], 'Media GPU layer coverage differs'
    assert invocation['SDK_layers_matched'] == parent['matched_SDK_layers_and_diffIDs'], 'Media SDK ancestry differs'
    assert invocation['ORT_WEB_REQUIRED'] == 1 and invocation['ORT_WASM_WEBGPU_FLAVORS'] is True, 'Both required Media Wasm modes must be retained'
    assert invocation['command'].count('ORT_WEB_REQUIRED=1') == invocation['command'].count('ORT_WASM_WEBGPU_FLAVORS=true') == 1, 'Media Wasm command flags differ'


def load_media(plan_path: Path, invocation_path: Path) -> tuple[Json, Json, Json]:
    invocation = json.loads(invocation_path.read_text())
    assert Path(invocation['output']) == invocation_path.resolve().parent, 'Media output binding differs'
    gpu_path, proof_path = Path(invocation['GPU_invocation']), Path(invocation['parent_OCI_proof'])
    assert sha(gpu_path) == invocation['GPU_invocation_sha256'] and sha(proof_path) == invocation['parent_OCI_proof_sha256'], 'Media parent receipt bytes changed'
    plan, gpu, sdk = load_gpu(plan_path, gpu_path)
    parent, _ = gpu_layout(proof_path, gpu_path, gpu, sdk)
    validate_media(invocation, parent, gpu)
    return plan, invocation, parent


def media_layout(proof_path: Path, invocation_path: Path, invocation: Json, parent: Json) -> tuple[Json, Path]:
    proof, context, native = parent_layout(proof_path)
    assert proof['status'] == STATUS and proof['Media_invocation'] == str(invocation_path.resolve()), 'Media OCI proof scope differs'
    assert proof['Media_invocation_sha256'] == sha(invocation_path), 'Media invocation bytes changed'
    assert proof['source_revision'] == invocation['source_revision'], 'Media OCI source differs'
    assert proof['parent_OCI_proof_sha256'] == invocation['parent_OCI_proof_sha256'], 'Media OCI GPU proof differs'
    assert proof['export_transport'] == {'producer_status': 0, 'extractor_status': 0} and proof['parent_layer_reuse_verified'], 'Media export transport failed'
    _, _, gpu = parent_layout(Path(invocation['parent_OCI_proof']))
    assert proof['matched_GPU_layers_and_diffIDs'] == parent['layers'], 'Media GPU coverage differs'
    layer_ancestry(native, gpu, parent['layers'])
    actual = actual_image(invocation)
    assert proof['manifest'] == actual['manifest'] and proof['config'] == actual['config'], 'Engine Media image differs'
    return proof, context
