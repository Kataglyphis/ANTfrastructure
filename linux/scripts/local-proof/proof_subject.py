"""Bind explicit compiler or amd64 SDK proof profiles; supplied receipts do not authenticate their provenance."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from proof_types import Json


def validate_sdk(plan: Json, invocation: Json, parent: Json, full: Json) -> None:
    assert invocation['target_arch'] == 'amd64', 'Only the reviewed amd64 SDK profile is supported'
    assert invocation['source'] == plan['source'] and invocation['source_revision'] == plan['source_revision'], 'SDK source differs from its compiler'
    assert invocation['parent_source_revision'] == plan['source_revision'], 'SDK compiler source differs'
    assert re.fullmatch(r'webgpu-normal-sdk-amd64-[0-9-]+\.service', invocation['unit']), 'Unexpected SDK producer unit'
    assert invocation['launch_status'] == 0 and invocation['publication'] is False, 'SDK launch was not a successful local invocation'
    assert invocation['source_full_preflight_passed'] and invocation['producer_source_unchanged'], 'SDK source proof was not retained'
    assert parent['status'] == 'passed-qualified-native-compiler-OCI-and-base-ancestry', 'SDK requires its actual qualified compiler parent'
    assert parent['SDK_parent_prerequisites_passed'] and parent['all_native_blob_sizes_and_sha256_verified'], 'Compiler parent is incomplete'
    assert parent['source_revision'] == plan['source_revision'] and parent['matched_base_layers_and_diffIDs'] == 12, 'Compiler ancestry differs'
    assert parent['manifest'] == invocation['parent_manifest'] and parent['config'] == invocation['parent_config'], 'SDK parent identity differs'
    assert parent['index_sha256'] == invocation['parent_OCI_index_sha256'] and parent['layers'] == 26, 'SDK requires the reviewed complete compiler layout'
    assert parent['stopped']['ActiveState'] == 'inactive' and parent['stopped']['MainPID'] == '0', 'Compiler handoff was not sealed'
    assert full['status'] == 'passed-complete-Linux-source-preflight-only' and full['source_revision'] == plan['source_revision'], 'SDK requires the exact complete source proof'
    assert full['actual_full_registry_mutations'] == plan['full_registry'], 'SDK source mutation coverage differs'
    assert full['command_exit_status'] == full['cleanup_exit_status'] == full['independent_engine_query_exit_status'] == 0, 'SDK source proof contains a failure'
    assert full['owned_container_absent'] and full['unit_stopped_after_seal'], 'SDK source proof lacks cleanup'
    command = invocation['command']
    repo = invocation['image'].removesuffix(':cross-sdk-amd64')
    assert repo.startswith('ant-local/webgpu-') and invocation['image'] == repo + ':cross-sdk-amd64', 'Unexpected SDK candidate name'
    assert command[:2] == ['systemd-run', '--user'] and '--expand-environment=no' in command, 'SDK transport differs'
    assert command[-10:] == ['/bin/bash', str(Path(plan['source']) / 'linux/scripts/build-cross-stage.sh'), '--stage', 'sdk', '--arch', 'amd64', '--image-repo', repo, '--log-dir', str(Path(invocation['output']) / 'logs')], 'SDK stage command differs'
    expected_base = 'CROSS_SDK_BASE_IMAGE=' + plan['local_image'].rsplit(':', 1)[0] + '@' + parent['manifest']
    assert command.count(expected_base) == 1 and command.count('CROSS_SDK_BASE_CONTEXT=' + parent['context']) == 1, 'SDK command is not bound to its qualified native parent'
    assert '--push' not in command and '--gates-only' not in command, 'SDK profile requires an actual local build'


def image_subject(plan: Json, invocation: Json | None = None, parent: Json | None = None, full: Json | None = None) -> Json:
    value = {'kind': 'compiler', 'image': plan['local_image'], 'producer_unit': plan['unit'],
             'native_prefix': '/opt/llvm-target-amd64', 'cpu_profile': 'compiler',
             'cross_required': plan.get('launcher_contract') == 2,
             'unit_prefix': 'webgpu-compiler-image-qualification-',
             'qualification_status': 'passed-fresh-image-baked-compiler-native-tool-and-loader-selection-only'}
    if invocation is not None:
        assert parent is not None and full is not None, 'SDK profile requires parent and source receipts'
        validate_sdk(plan, invocation, parent, full)
        value.update(kind='sdk-amd64', image=invocation['image'], producer_unit=invocation['unit'],
                     native_prefix='/opt/llvm-target', cpu_profile='sdk-amd64', cross_required=False,
                     unit_prefix='webgpu-sdk-image-qualification-',
                     qualification_status='passed-fresh-SDK-native-tool-and-loader-selection-only')
    return value


def validate_subject_binding(record: Json, subject: Json, *, cpu_checks: bool = False) -> None:
    sdk = subject['kind'] == 'sdk-amd64'
    assert record.get('subject', subject if not sdk else None) == subject, 'Stored proof subject differs'
    if cpu_checks:
        assert record.get('sdk_native_checks_required', False) == sdk, 'Stored SDK CPU requirement differs'
        assert record.get('cross_wrapper_checks_required', False) == subject['cross_required'], 'Stored cross-wrapper requirement differs'


def load_subject(plan: Json, sdk_invocation: Path | None) -> Json:
    if sdk_invocation is None:
        return image_subject(plan)
    invocation = json.loads(sdk_invocation.read_text())
    invocation = {**invocation, 'output': str(sdk_invocation.resolve().parent)}
    parent_path = Path(invocation['parent_OCI_proof'])
    full_path = Path(invocation['SDK_source_full_preflight_proof'])
    value = image_subject(plan, invocation, json.loads(parent_path.read_text()), json.loads(full_path.read_text()))
    value.update(sdk_invocation=str(sdk_invocation.resolve()), compiler_parent_proof=str(parent_path.resolve()),
                 sdk_invocation_sha256=hashlib.sha256(sdk_invocation.read_bytes()).hexdigest(),
                 compiler_parent_sha256=hashlib.sha256(parent_path.read_bytes()).hexdigest(),
                 source_proof_sha256=hashlib.sha256(full_path.read_bytes()).hexdigest())
    return value
