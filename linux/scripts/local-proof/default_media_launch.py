"""Launch default amd64 Media from its qualified SDK; no foreign lane, OCI export, factory, licence or FINAL acceptance."""

from __future__ import annotations

import argparse
import json
import re
import runpy
import sys
from pathlib import Path
from typing import TYPE_CHECKING

from native_oci_layout import sha
from normal_stage_launch import downstream_record, full_source, launch_build
from webgpu_media_lanes import media_inputs

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from source_ci.common import require

if TYPE_CHECKING:
    from proof_types import Json

MEDIA_REQUIRED_BYTES = 300 * 1024**3


def sdk_media_parent(plan_path: Path, invocation_path: Path, proof_path: Path) -> tuple[Json, Json, Json, Path]:
    require(__debug__, 'Optimization disables shared parent safety assertions')
    plan = json.loads(plan_path.read_text())
    invocation = json.loads(invocation_path.read_text())
    source = Path(plan['source'])
    full_source(source, Path(plan['full_source_preflight_proof']), plan['source_revision'])
    require(invocation['target_arch'] == 'amd64', 'Default Media requires the reviewed amd64 SDK')
    require(invocation['source'] == str(source) and invocation['source_revision'] == plan['source_revision'],
            'Media must retain its exact SDK source')
    api = runpy.run_path(str(Path(__file__).with_name('launch-normal-gpu.py')))
    require(callable(api.get('sdk_parent')), 'The qualified SDK parent API is missing')
    parent, context = api['sdk_parent'](plan, invocation_path, proof_path)
    require(parent['subject']['sdk_invocation_sha256'] == sha(invocation_path), 'SDK invocation changed after qualification')
    full_path = Path(invocation['SDK_source_full_preflight_proof'])
    full_sha = sha(full_path)
    require(parent['subject']['source_proof_sha256'] == full_sha, 'SDK source proof changed after qualification')
    invocation = {**invocation, 'source_full_preflight_proof': str(full_path), 'source_full_preflight_sha256': full_sha}
    return plan, invocation, parent, context


def launch(plan_path: Path, invocation_path: Path, proof_path: Path, output: Path, unit: str, repo: str) -> int:
    require(re.fullmatch(r'webgpu-normal-media-default-amd64-[0-9-]+\.service', unit) is not None,
            'Explicit default amd64 Media unit required')
    plan, invocation, parent, context = sdk_media_parent(plan_path, invocation_path, proof_path)
    source = Path(invocation['source'])
    reference = invocation['image'].rsplit(':', 1)[0] + '@' + parent['manifest']
    selected = media_inputs(source, output.resolve(), repo, 'default', 'amd64', 'sdk', context, reference)
    record = downstream_record(invocation, invocation_path, proof_path, parent, 'SDK')
    peers = ('launch-default-amd64-media.py', 'default_media_launch.py', 'normal_stage_launch.py',
             'webgpu_media_lanes.py', 'launch-normal-gpu.py')
    record.update(stage='media', variant='default', parent_kind='SDK', SDK_layers_rehashed=parent['layers'],
                  compiler_layers_matched=parent['matched_compiler_layers_and_diffIDs'],
                  ORT_WEB_REQUIRED=1, ORT_WASM_WEBGPU_FLAVORS=True,
                  launcher_inputs_sha256={name: sha(Path(__file__).with_name(name)) for name in peers},
                  scope=__doc__, GPU_or_FINAL_acceptance=False)
    required = max(MEDIA_REQUIRED_BYTES, plan['required_bytes'])
    return launch_build(source, output.resolve(), unit, selected['image'], 'amd64', required, record,
                        selected['environment'], selected['driver'])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('compiler-plan', 'sdk-invocation', 'parent-proof', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--unit', required=True)
    parser.add_argument('--image-repo', required=True)
    args = parser.parse_args()
    return launch(args.compiler_plan, args.sdk_invocation, args.parent_proof, args.output, args.unit, args.image_repo)
