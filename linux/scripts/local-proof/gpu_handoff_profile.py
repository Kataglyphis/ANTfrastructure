"""Bind an actual ordinary ROCm amd64 producer and native SDK ancestry; no receipt authentication, licence closure or inference proof."""

from __future__ import annotations

import json
import re
import runpy
from pathlib import Path
from typing import TYPE_CHECKING

from gpu_source_profile import select_gpu_source
from native_oci_layout import sha
from normal_stage_launch import full_source, validate_stage_invocation
from proof_commands import checked_run
from stage_handoff_profile import native_stage_layout

if TYPE_CHECKING:
    from proof_types import Json

STATUS = 'passed-native-ROCm-GPU-OCI-and-SDK-ancestry-only'


def terminal(unit: str) -> Json:
    raw = checked_run(['systemctl', '--user', 'show', unit, '--property=Id,LoadState,ActiveState,SubState,MainPID,Result,ExecMainStatus']).stdout
    value = dict(line.split('=', 1) for line in raw.splitlines())
    assert value['Id'] == unit and value['LoadState'] == 'loaded', 'Producer unit is missing'
    assert value['ActiveState'] == 'active' and value['SubState'] == 'exited', 'Producer has not succeeded'
    assert value['MainPID'] == value['ExecMainStatus'] == '0' and value['Result'] == 'success', 'Producer failed or remains live'
    return value


def validate_gpu(invocation: Json, parent: Json) -> None:
    assert invocation['stage'] == 'gpu' and invocation['variant'] == 'rocm' and invocation['target_arch'] == 'amd64', 'Only ordinary ROCm amd64 is reviewed'
    validate_stage_invocation(invocation, parent, 'gpu', parent['subject']['image'])
    assert invocation['SDK_layers_rehashed'] == parent['layers'] and invocation['compiler_layers_rehashed'] == 26, 'GPU ancestry coverage differs'


def load_gpu(plan_path: Path, invocation_path: Path) -> tuple[Json, Json, Json]:
    plan = json.loads(plan_path.read_text())
    invocation = json.loads(invocation_path.read_text())
    assert Path(invocation['output']) == invocation_path.resolve().parent, 'GPU output binding differs'
    full_source(Path(plan['source']), Path(plan['full_source_preflight_proof']), plan['source_revision'])
    sdk_invocation, parent_path = Path(invocation['SDK_invocation']), Path(invocation['parent_OCI_proof'])
    assert sha(sdk_invocation) == invocation['SDK_invocation_sha256'] and sha(parent_path) == invocation['parent_OCI_proof_sha256'], 'GPU SDK receipt bytes changed'
    module = runpy.run_path(str(Path(__file__).with_name('launch-normal-gpu.py')))
    parent, _ = module['sdk_parent'](plan, sdk_invocation, parent_path)
    validate_gpu(invocation, parent)
    alternate = invocation['source_revision'] != plan['source_revision']
    source, revision, full, review = select_gpu_source(plan, Path(invocation['source']) if alternate else None,
                                                      Path(invocation['source_full_preflight_proof']) if alternate else None)
    assert str(source) == invocation['source'] and revision == invocation['source_revision'], 'GPU source differs'
    assert sha(full) == invocation['source_full_preflight_sha256'] and invocation['GPU_source_review'] == review, 'GPU source review differs'
    assert invocation['parent_source_revision'] == plan['source_revision'], 'GPU parent source differs'
    return plan, invocation, parent


def actual_image(invocation: Json) -> Json:
    terminal(invocation['unit'])
    engine = str(Path.home() / '.local/bin/nerdctl')
    images = json.loads(checked_run([engine, 'image', 'inspect', invocation['image']]).stdout)
    assert len(images) == 1, 'GPU engine query must select one image'
    actual = images[0]
    digests = {value.rsplit('@', 1)[1] for value in actual['RepoDigests']}
    assert len(digests) == 1, 'GPU image manifest is ambiguous'
    manifest = digests.pop()
    assert re.fullmatch(r'sha256:[0-9a-f]{64}', manifest), 'GPU manifest is malformed'
    assert re.fullmatch(r'sha256:[0-9a-f]{64}', actual['Id']), 'GPU config is malformed'
    resolved = json.loads(checked_run([engine, 'image', 'inspect', manifest]).stdout)
    assert len(resolved) == 1 and resolved[0]['Id'] == actual['Id'], 'Local immutable manifest selector differs'
    assert {value.rsplit('@', 1)[1] for value in resolved[0]['RepoDigests']} == {manifest}, 'Local immutable manifest digest differs'
    return {'manifest':manifest, 'config':actual['Id'], 'image':invocation['image']}


def gpu_layout(proof_path: Path, invocation_path: Path, invocation: Json, parent: Json) -> tuple[Json, Path]:
    return native_stage_layout(proof_path, invocation_path, invocation, parent, 'GPU', 'SDK', STATUS, actual_image)
