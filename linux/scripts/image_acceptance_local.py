"""Bind local FINAL consumers to a completed runtime and engine identity; supplied receipts do not authenticate sources, prove binary licences or GPU inference."""

from __future__ import annotations

import importlib
import json
import re
import subprocess
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import runtime_terminal_evidence as terminal_evidence
from source_ci.common import fingerprint, require

LOCAL_REF = re.compile(r'docker.io/ant-local/webgpu-[a-z0-9_./-]+@sha256:[0-9a-f]{64}\Z')
SHA = re.compile(r'[0-9a-f]{40}\Z')
HASH = re.compile(r'[0-9a-f]{64}\Z')
DIGEST = re.compile(r'sha256:[0-9a-f]{64}\Z')
KIND = 'local-runtime-final'
LANES = {('', 'amd64'), ('', 'arm64'), ('', 'riscv64'), ('rocm', 'amd64'), ('nvidia', 'amd64'), ('nvidia', 'arm64')}
ACCELERATORS = {'': ('false', 'false'), 'rocm': ('true', 'false'), 'nvidia': ('false', 'true')}


def local_api(name: str) -> ModuleType:
    directory = Path(__file__).resolve().parent / 'local-proof'
    sys.path.insert(0, str(directory))
    module = importlib.import_module(name)
    require(module.__file__ is not None and Path(module.__file__).resolve() == directory / (name + '.py'), 'Local producer API belongs to another checkout')
    return module


def output(command: list[str]) -> str:
    result = subprocess.run(command, text=True, capture_output=True, timeout=60, check=False)
    require(result.returncode == 0, f'Local subject query failed ({result.returncode}): {result.stdout}{result.stderr}')
    return result.stdout


def text(value: dict[str, Any], key: str, pattern: re.Pattern[str] | None = None) -> str:
    result = value.get(key)
    if not isinstance(result, str) or not result or (pattern is not None and not pattern.fullmatch(result)):
        raise ValueError('Missing or invalid local producer field: ' + key)
    return result


def read_object(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding='utf-8'))
    require(isinstance(value, dict), 'Local producer evidence must be an object')
    return value


def validate_reference(image: str) -> None:
    require(LOCAL_REF.fullmatch(image) is not None, 'Local acceptance needs an immutable docker.io/ant-local/webgpu reference')


def complete_plan(plan: dict[str, Any], canonical: dict[str, Any]) -> None:
    require({**plan, 'platform': canonical['platform']} == canonical, 'Local FINAL acceptance requires the complete canonical consumer contract')


def command_binding(invocation: dict[str, Any], android: dict[str, Any], platform: str, parent: str) -> None:
    arch = platform.removeprefix('linux/')
    command = invocation.get('command')
    if not isinstance(command, list) or not all(isinstance(value, str) for value in command):
        raise ValueError('Local runtime command is missing')
    source, prefix = text(invocation, 'source'), text(invocation, 'image_prefix')
    expected = ['/bin/bash', str(Path(source) / 'linux/scripts/build-runtime-manifest.sh'), '--image', prefix,
                '--target-arches', arch, '--artifact-image-prefix', text(android, 'image').removesuffix('-' + arch),
                '--artifact-build-mode', 'cross', '--skip-manifest']
    require(command[:2] == ['systemd-run', '--user'] and command[-11:] == expected, 'Local runtime driver differs')
    require('--expand-environment=no' in command and '--unit=' + invocation['unit'] in command, 'Local runtime transport differs')
    require(invocation.get('image') == prefix + '-' + arch, 'Local subject is not the final runtime wrapper')
    amd, nvidia = ACCELERATORS[invocation['variant']]
    flags = {'CROSS_VARIANT':invocation['variant'], 'ENABLE_AMD':amd, 'ENABLE_NVIDIA':nvidia, 'RUNTIME_WHEELS_SOURCE':'image', 'RUNTIME_IMAGE_SMOKE':'1', 'RUNTIME_INPUT_PREFLIGHT':'1',
             'WRAPPER_CONTENT_GATE':'1', 'ANCESTRY_STAMP_ENFORCE':'1', 'CROSS_NO_PUSH':'1', 'ARTIFACT_CONTEXT_MODE':'oci',
             'CROSS_RUN_ID':text(invocation, 'expected_runtime_run_id', re.compile(r'runtime-[0-9a-f]{32}\Z')), 'APP_REF':text(invocation, 'app_ref', SHA)}
    for name, expected_value in flags.items():
        require([value for value in command if value.startswith(name + '=')] == [name + '=' + expected_value], 'Local runtime gate or pin differs: ' + name)
    require('--push' not in command and '--gates-only' not in command, 'Actual unpublished local runtime required')
    key = 'RUNTIME_ANDROID_PIN_' + arch + '='
    require([value for value in command if value.startswith(key)] == [key + parent], 'Runtime Android pin differs')


def producer_inputs(invocation: dict[str, Any], path: Path, platform: str) -> dict[str, Any]:
    arch = platform.removeprefix('linux/')
    require(platform in {'linux/amd64', 'linux/arm64', 'linux/riscv64'} and invocation.get('target_arch') == arch, 'Local runtime platform differs')
    variant = invocation.get('variant')
    require(invocation.get('stage') == 'runtime' and isinstance(variant, str) and (variant, arch) in LANES, 'Local FINAL producer must be a supported ordinary Linux runtime lane')
    require(type(invocation.get('launch_status')) is int and invocation['launch_status'] == 0 and invocation.get('publication') is False, 'Actual unpublished producer launch required')
    unit = text(invocation, 'unit', re.compile(r'webgpu-normal-runtime-' + arch + r'-[0-9-]+\.service\Z'))
    require(Path(text(invocation, 'output')).resolve() == path.parent, 'Local runtime invocation directory differs')
    require(invocation.get('source_full_preflight_passed') is True and invocation.get('producer_source_unchanged') is True, 'Complete runtime source proof required')
    source, proof = Path(text(invocation, 'source')), Path(text(invocation, 'source_full_preflight_proof'))
    require(fingerprint(proof) == text(invocation, 'source_full_preflight_sha256', HASH), 'Runtime complete source proof changed')
    try:
        local_api('normal_stage_launch').full_source(source, proof, text(invocation, 'source_revision', SHA))
    except AssertionError as error:
        raise ValueError('Local runtime source or terminal producer failed: ' + str(error)) from error
    try:
        terminal = local_api('gpu_handoff_profile').terminal(unit)
    except AssertionError as error:
        if str(error) != 'Producer unit is missing':
            raise ValueError('Local runtime source or terminal producer failed: ' + str(error)) from error
        host_binding(invocation)
        return {**terminal_evidence.recover(invocation, path, output), 'runtime_proof_sha256':fingerprint(proof)}
    raw = output(['systemctl', '--user', 'show', unit, '--property=ExecMainExitTimestampMonotonic', '--value']).strip()
    require(raw.isdigit() and int(raw) > 0, 'Local runtime never exited')
    return {'unit': terminal, 'exit_timestamp_monotonic': int(raw), 'runtime_proof_sha256': fingerprint(proof)}


def host_binding(invocation: dict[str, Any]) -> None:
    wrapper = Path(text(invocation, 'engine_wrapper')).resolve(strict=True)
    require(wrapper.name == 'owned-nerdctl.py' and wrapper.parent.name == 'scripts' and wrapper.parent.parent.name == 'linux', 'Runtime engine wrapper layout differs')
    host = wrapper.parents[2]
    require(output(['git', '-C', str(host), 'rev-parse', 'HEAD']).strip() == text(invocation, 'host_tools_revision', SHA), 'Runtime host source revision differs')
    require(not output(['git', '-C', str(host), 'status', '--porcelain']).strip(), 'Runtime host source changed')
    workers = local_api('runtime_launch_profile').runtime_worker_files(host)
    require(invocation.get('selected_host_workers_sha256') == {str(path): fingerprint(path) for path in workers}, 'Runtime worker closure changed')


def parent_binding(invocation: dict[str, Any], platform: str) -> tuple[dict[str, Any], str]:
    android_path, proof_path = Path(text(invocation, 'Android_invocation')), Path(text(invocation, 'parent_OCI_proof'))
    require(fingerprint(android_path) == text(invocation, 'Android_invocation_sha256', HASH) and fingerprint(proof_path) == text(invocation, 'parent_OCI_proof_sha256', HASH), 'Original Android evidence changed')
    android, proof = read_object(android_path), read_object(proof_path)
    require(android.get('stage') == 'android' and android.get('target_arch') == platform.removeprefix('linux/') and android.get('variant') == invocation['variant'], 'Original Android lane differs')
    require(android.get('source_revision') == proof.get('source_revision') == text(invocation, 'parent_source_revision', SHA), 'Original Android source differs')
    require(proof.get('manifest') == text(invocation, 'parent_manifest', DIGEST) and proof.get('config') == text(invocation, 'parent_config', DIGEST), 'Original Android image differs')
    reference = 'docker.io/' + text(android, 'image').rsplit(':', 1)[0] + '@' + invocation['parent_manifest']
    return android, reference


def cleanup_binding(invocation: dict[str, Any], directory: Path, engine: str) -> str:
    run_id = text(invocation, 'run_id', re.compile(r'[0-9a-f]{32}\Z'))
    require(invocation.get('expected_runtime_run_id') == 'runtime-' + run_id and invocation.get('owner_label') == 'org.kataglyphis.normal-runtime', 'Runtime ownership differs')
    path = directory / 'cleanup.json'
    cleanup = read_object(path)
    require(type(cleanup.get('exit_status')) is int and cleanup['exit_status'] == 0 and cleanup.get('run_id') == run_id and cleanup.get('owner_label') == invocation['owner_label'], 'Runtime cleanup did not succeed')
    raw = output([engine, 'ps', '-a', '--filter', 'label=' + invocation['owner_label'] + '=' + run_id, '--format', '{{json .}}'])
    require(not raw.strip(), 'Runtime still owns containers: ' + raw)
    return fingerprint(path)


def one_image(engine: str, reference: str) -> dict[str, Any]:
    values = json.loads(output([engine, 'image', 'inspect', reference]))
    require(isinstance(values, list) and len(values) == 1 and isinstance(values[0], dict), 'Local engine query must select one image object')
    return values[0]


def image_identity(invocation: dict[str, Any], image: str, platform: str, parent: str, engine: str) -> dict[str, Any]:
    actual = one_image(engine, text(invocation, 'image'))
    manifest = image.rsplit('@', 1)[1]
    config = text(actual, 'Id', DIGEST)
    require({value.rsplit('@', 1)[1] for value in actual.get('RepoDigests', [])} == {manifest}, 'Local runtime manifest differs')
    require(actual.get('Os') == 'linux' and actual.get('Architecture') == platform.removeprefix('linux/'), 'Local engine image platform differs')
    config_data = actual.get('Config', {})
    require(isinstance(config_data, dict) and isinstance(config_data.get('Labels'), dict), 'Local runtime image config labels are malformed')
    labels = config_data['Labels']
    required = {'org.kataglyphis.run-id':invocation['expected_runtime_run_id'], 'org.kataglyphis.parent-stage':'android',
                'org.kataglyphis.parent-digest':parent, 'org.opencontainers.image.revision':invocation['source_revision'],
                'org.opencontainers.image.version':invocation['app_ref']}
    require(all(labels.get(key) == value for key, value in required.items()), 'Local runtime provenance or app label differs')
    resolved = one_image(engine, manifest)
    require(resolved.get('Id') == config and {value.rsplit('@', 1)[1] for value in resolved.get('RepoDigests', [])} == {manifest}, 'Local immutable manifest/config differs')
    subject = {'image':invocation['image'], 'manifest':manifest, 'config':config}
    require(local_api('runtime_launch_profile').local_reference(subject) == image, 'Local reference belongs to another repository')
    return subject


def observe(engine: str, image: str, platform: str, invocation_path: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    validate_reference(image)
    invocation_path = invocation_path.resolve(strict=True)
    invocation = read_object(invocation_path)
    origin = producer_inputs(invocation, invocation_path, platform)
    host_binding(invocation)
    android, parent = parent_binding(invocation, platform)
    command_binding(invocation, android, platform, parent)
    cleanup = cleanup_binding(invocation, invocation_path.parent, engine)
    subject = image_identity(invocation, image, platform, parent, engine)
    origin.update(kind=KIND, platform=platform, variant=invocation['variant'], image=image, config=subject['config'],
                  producer_invocation=str(invocation_path), producer_invocation_sha256=fingerprint(invocation_path),
                  source_revision=invocation['source_revision'], host_tools_revision=invocation['host_tools_revision'],
                  parent_manifest=invocation['parent_manifest'], parent_config=invocation['parent_config'],
                  parent_source_revision=invocation['parent_source_revision'], cleanup_sha256=cleanup,
                  original_Android_sha256=invocation['Android_invocation_sha256'], parent_proof_sha256=invocation['parent_OCI_proof_sha256'],
                  runtime_run_id=invocation['expected_runtime_run_id'])
    return origin, subject


def prepare(engine: str, image: str, platform: str, invocation: str, workspace: Path) -> dict[str, Any]:
    origin, subject = observe(engine, image, platform, Path(invocation))
    local_api('runtime_launch_profile').prepare_local_alias(subject, workspace / 'local-image-alias.json', platform=platform, engine=engine)
    return origin


def verify_alias(engine: str, image: str, platform: str, subject: dict[str, Any]) -> None:
    rows = local_api('runtime_launch_profile').alias_inventory(engine, image)
    require(len(rows) == 1 and rows[0].get('Digest') == subject['manifest'] and rows[0].get('Platform') == platform, 'Local digest alias differs')


def recheck(engine: str, image: str, platform: str, invocation: str, before: dict[str, Any]) -> dict[str, Any]:
    after, subject = observe(engine, image, platform, Path(invocation))
    verify_alias(engine, image, platform, subject)
    require(after == before, 'Local runtime identity or producer evidence changed during consumer checks')
    return after


def validate_receipt(receipt: dict[str, Any], image: str, platform: str) -> None:
    validate_reference(image)
    before, after = receipt.get('local_subject'), receipt.get('local_subject_after')
    if not isinstance(before, dict) or before != after or before.get('kind') != KIND:
        raise ValueError('Local subject evidence is missing or changed')
    require(before.get('image') == image and before.get('platform') == platform, 'Local subject/platform differs')
    variant = before.get('variant')
    require(isinstance(variant, str) and (variant, platform.removeprefix('linux/')) in LANES, 'Local receipt runtime lane is unsupported')
    for key in ['producer_invocation_sha256', 'runtime_proof_sha256', 'cleanup_sha256', 'original_Android_sha256', 'parent_proof_sha256']:
        text(before, key, HASH)
    for key in ['source_revision', 'parent_source_revision', 'host_tools_revision']:
        text(before, key, SHA)
    for key in ['config', 'parent_manifest', 'parent_config']:
        text(before, key, DIGEST)
    terminal = before.get('unit', {})
    require(isinstance(terminal, dict), 'Local receipt producer unit is malformed')
    text(terminal, 'Id', re.compile(r'webgpu-normal-runtime-' + platform.removeprefix('linux/') + r'-[0-9-]+\.service\Z'))
    require(terminal.get('LoadState') == 'loaded' and terminal.get('ActiveState') == 'active' and terminal.get('SubState') == 'exited', 'Local receipt producer was not terminal')
    require(terminal.get('MainPID') == terminal.get('ExecMainStatus') == '0' and terminal.get('Result') == 'success', 'Local receipt producer failed or was live')
    require(type(before.get('exit_timestamp_monotonic')) is int and before['exit_timestamp_monotonic'] > 0, 'Local receipt producer never exited')
    terminal_evidence.validate(before)
    require(Path(text(before, 'producer_invocation')).is_absolute(), 'Local producer invocation path must be absolute')
    text(receipt, 'local_alias_receipt')
    text(receipt, 'local_alias_sha256', HASH)
    text(before, 'runtime_run_id', re.compile(r'runtime-[0-9a-f]{32}\Z'))
