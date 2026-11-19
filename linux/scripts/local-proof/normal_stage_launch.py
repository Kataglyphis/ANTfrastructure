"""Share ordinary local stage admission and transport; no image, cache or GPU acceptance."""

from __future__ import annotations

import datetime
import json
import re
import runpy
import shlex
import subprocess
import sys
from pathlib import Path
from typing import TYPE_CHECKING

from native_oci_layout import sha
from proof_commands import checked_run

if TYPE_CHECKING:
    from collections.abc import Callable

    from proof_types import Json


def validate_stage_invocation(invocation: Json, parent: Json, stage: str, parent_image: str) -> None:
    assert stage in {'gpu', 'media', 'android'} and invocation['target_arch'] == 'amd64', 'Unreviewed ordinary downstream stage'
    assert re.fullmatch(r'webgpu-normal-' + stage + r'-amd64-[0-9-]+\.service', invocation['unit']), 'Unexpected downstream producer unit'
    assert invocation['launch_status'] == 0 and invocation['publication'] is False, 'Successful unpublished downstream launch required'
    assert invocation['source_full_preflight_passed'] and invocation['producer_source_unchanged'], 'Downstream source proof was not retained'
    for field in ('manifest', 'config'):
        assert invocation['parent_' + field] == parent[field], 'Downstream parent identity differs'
    assert invocation['parent_OCI_index_sha256'] == parent['index_sha256'], 'Downstream parent index differs'
    source, output = Path(invocation['source']), Path(invocation['output'])
    suffix = {'gpu': ':cross-toolchain-rocm-amd64', 'media': ':cross-media-rocm-amd64', 'android': ':cross-android-rocm-amd64'}[stage]
    repo = invocation['image'].removesuffix(suffix)
    assert repo.startswith('ant-local/webgpu-') and invocation['image'] == repo + suffix, 'Unexpected local downstream image'
    command = invocation['command']
    assert command[:2] == ['systemd-run', '--user'] and '--expand-environment=no' in command, 'Downstream transport differs'
    assert command[-10:] == ['/bin/bash', str(source / 'linux/scripts/build-cross-stage.sh'), '--stage', stage, '--arch', 'amd64', '--image-repo', repo, '--log-dir', str(output / 'logs')], 'Downstream stage command differs'
    assert command.count('CROSS_VARIANT=rocm') == 1 and command.count('CROSS_' + stage.upper() + '_BASE_CONTEXT=' + parent['context']) == 1, 'Downstream context or variant differs'
    references = [item for item in command if item.startswith('CROSS_' + stage.upper() + '_BASE_IMAGE=')]
    expected = 'CROSS_' + stage.upper() + '_BASE_IMAGE=' + parent_image.rsplit(':', 1)[0] + '@' + parent['manifest']
    assert references == [expected], 'Downstream parent must use its actual repository and digest'
    assert '--push' not in command and '--gates-only' not in command, 'Actual unpublished downstream build required'


def downstream_record(invocation: Json, invocation_path: Path, proof_path: Path, parent: Json, parent_kind: str) -> Json:
    assert parent_kind in {'GPU', 'Media', 'Android'}, 'Unreviewed downstream parent kind'
    return {'source_revision': invocation['source_revision'], 'parent_source_revision': invocation['source_revision'],
            'source_full_preflight_proof': invocation['source_full_preflight_proof'],
            'source_full_preflight_sha256': invocation['source_full_preflight_sha256'],
            'source_full_preflight_passed': True, 'producer_source_unchanged': True,
            parent_kind + '_invocation': str(invocation_path.resolve()),
            parent_kind + '_invocation_sha256': sha(invocation_path),
            'parent_OCI_proof': str(proof_path.resolve()), 'parent_OCI_proof_sha256': sha(proof_path),
            'parent_manifest': parent['manifest'], 'parent_config': parent['config'],
            'parent_OCI_index_sha256': parent['index_sha256']}


def full_source(source: Path, proof_path: Path, revision: str) -> Json:
    assert checked_run(['git', '-C', str(source), 'rev-parse', 'HEAD']).stdout.strip() == revision, 'Source revision differs'
    assert not checked_run(['git', '-C', str(source), 'status', '--porcelain']).stdout.strip(), 'Source must be clean'
    proof = json.loads(proof_path.read_text())
    registry = json.loads((source / 'docs/scripts/mutations.json').read_text())
    assert proof['status'] == 'passed-complete-Linux-source-preflight-only' and proof['source_revision'] == revision, 'Complete exact source proof required'
    assert proof['actual_full_registry_mutations'] == len(registry) == len({row['id'] for row in registry}), 'Full mutation coverage differs'
    assert proof['actual_preflight_group_count'] == len(proof['all_default_preflight_groups']) == 42, 'All preflight groups are required'
    assert proof['command_exit_status'] == proof['cleanup_exit_status'] == proof['independent_engine_query_exit_status'] == 0, 'Source proof contains a failed command'
    assert proof['unit_stopped_after_seal'] and proof['owned_container_absent'], 'Source proof lacks cleanup'
    assert proof['script_suites'] > 0 and proof['script_assertions'] > 0, 'Source proof lacks actual suite accounting'
    return proof


def host_admission(unit: str, output: Path, image: str | tuple[str, ...]) -> Path:
    manager = dict(line.split('=', 1) for line in checked_run(['systemctl', '--user', 'show-environment']).stdout.splitlines() if '=' in line)
    assert not {key for key in manager if key.startswith(('CROSS_', 'RUNTIME_', 'ARTIFACT_', 'WRAPPER_', 'TORCH_'))
                or key in {'ENABLE_AMD', 'ENABLE_NVIDIA', 'ENABLE_DEEPSTREAM', 'DRY_RUN', 'APP_REF', 'ONNX_PACKAGE', 'PYTORCH_EXTRA',
                           'HOST_PAYLOAD_ARCHES', 'BASE_PARENT_IMAGE', 'BASE_DOCKERFILE_PATH', 'PACKAGE_DOCKERFILE_PATH',
                           'PACKAGE_DOCKERFILE_TARGET', 'ANCESTRY_STAMP_ENFORCE'}}, 'Ambient build flags must be absent'
    assert checked_run(['systemctl', '--user', 'show', unit, '--property=LoadState', '--value']).stdout.strip() == 'not-found', 'Unit already exists'
    assert not output.exists(), 'Preserve existing stage output'
    temporary = Path.home() / '.cache' / unit.removesuffix('.service')
    assert not temporary.exists() and all(not (path / '.git').exists() for path in [temporary, *temporary.parents]), 'Temporary root must be fresh and outside Git'
    engine = str(Path.home() / '.local/bin/nerdctl')
    inventory = [json.loads(line) for line in checked_run([engine, 'images', '--format', '{{json .}}']).stdout.splitlines() if line.strip()]
    requested = {image} if isinstance(image, str) else set(image)
    assert not requested.intersection({f"{row['Repository']}:{row['Tag']}" for row in inventory}), 'Preserve the existing image alias'
    assert not checked_run([engine, 'ps', '--format', '{{.ID}}']).stdout.strip(), 'Another container is running'
    processes = checked_run(['ps', '-eo', 'pid,args']).stdout.splitlines()
    assert not [line for line in processes if re.search(r'(?:nerdctl|buildctl)\S*\s+build\b|build-(?:cross-(?:chain|stage)|runtime-(?:manifest|artifacts))\.sh', line)], 'Another build is running'
    return temporary


def launch_build(source: Path, output: Path, unit: str, image: str, arch: str, required_bytes: int,
                 record: Json, environment: list[str], driver: list[str], *, images: tuple[str, ...] = (),
                 prepare: Callable[[], Json] | None = None, engine_path: str | None = None,
                 cleanup: list[str] | None = None) -> int:
    temporary = host_admission(unit, output, images or image)
    sys.path.insert(0, str(source / 'linux/scripts'))
    disk = runpy.run_path(str(source / 'linux/scripts/launch-migraphx-configure-proof.py'))['require_build_disk'](output.parent)
    assert required_bytes >= 193273528320 and disk['available_bytes'] >= required_bytes, (
        f'Selected disk reserve {required_bytes} bytes required; {disk["available_bytes"]} available')
    disk['required_bytes'] = required_bytes
    output.mkdir()
    temporary.mkdir(mode=0o700)
    engine = engine_path or str(Path.home() / '.local/bin/nerdctl')
    command = ['systemd-run', '--user', '--no-block', '--expand-environment=no', f'--unit={unit}',
               '-p', 'Type=oneshot', '-p', 'RemainAfterExit=yes', '-p', 'TimeoutStartSec=21600', '-p', 'TimeoutStopSec=300',
               '-p', 'KillMode=control-group', '-p', f'WorkingDirectory={source}',
               '-p', f'StandardOutput=append:{output}/unit.log', '-p', f'StandardError=append:{output}/unit.log',
               '-E', 'LC_ALL=C', '-E', f'HOME={Path.home()}', '-E', f'PATH={Path.home()}/.local/bin:/usr/local/bin:/usr/bin:/bin',
               '-E', f'NERDCTL_BIN={engine}', '-E', 'BUILDKIT_PROGRESS=plain', '-E', f'BUILDKIT_CACHE_DIR={output}/buildcache',
               '-E', f'TMPDIR={temporary}']
    if cleanup is not None:
        command += ['-p', 'ExecStopPost=' + shlex.join(cleanup)]
    for value in environment:
        command += ['-E', value]
    command += driver
    record.update(created_at=datetime.datetime.now(datetime.UTC).isoformat(), unit=unit, source=str(source),
                  output=str(output), target_arch=arch, image=image, command=command, disk_admission=disk,
                  outlives_turn=True, publication=False)
    path = output / 'invocation.json'
    path.write_text(json.dumps(record, indent=2) + '\n')
    if prepare is not None:
        record.update(prepare())
        path.write_text(json.dumps(record, indent=2) + '\n')
    result = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
    record.update(launch_status=result.returncode, stdout=result.stdout, stderr=result.stderr)
    path.write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps({'unit':unit, 'launch_status':result.returncode, 'parent_manifest':record['parent_manifest'], 'disk':disk}))
    return result.returncode


def stage_inputs(source: Path, output: Path, repo: str, stage: str, arch: str,
                 context: Path, reference: str, variant: str) -> tuple[str, list[str], list[str]]:
    image = checked_run(['env', '-u', 'ENABLE_AMD', '-u', 'ENABLE_NVIDIA', 'bash', '-euo', 'pipefail', '-c',
                         '_TAG_NAMING_SH_LOADED=; source "$1"; IMAGE_REPO="$2"; CROSS_VARIANT="$3"; "$4" "$5"',
                         'normal-stage-tag', str(source / 'linux/scripts/01-core/tag-naming.sh'), repo, variant,
                         {'gpu':'cross_gpu_tag', 'sdk':'cross_sdk_tag', 'media':'cross_media_tag', 'android':'cross_android_tag'}[stage], arch]).stdout.strip()
    environment = [f'CROSS_{stage.upper()}_BASE_IMAGE={reference}', f'CROSS_{stage.upper()}_BASE_CONTEXT={context}']
    if variant:
        environment += [f'CROSS_VARIANT={variant}']
    if stage == 'media':
        environment += ['ORT_WEB_REQUIRED=1', 'ORT_WASM_WEBGPU_FLAVORS=true']
    driver = ['/bin/bash', str(source / 'linux/scripts/build-cross-stage.sh'), '--stage', stage, '--arch', arch,
              '--image-repo', repo, '--log-dir', str(output / 'logs')]
    return image, environment, driver


def launch_stage(source: Path, output: Path, unit: str, repo: str, stage: str, arch: str,
                 context: Path, reference: str, required_bytes: int, record: Json, variant: str = '') -> int:
    assert stage in {'sdk', 'gpu', 'media', 'android'} and variant in {'', 'rocm'}, 'Unreviewed stage profile'
    assert (stage in {'gpu', 'media', 'android'}) == bool(variant) and (stage == 'sdk' or arch == 'amd64'), 'Unreviewed GPU architecture'
    assert repo.startswith('ant-local/webgpu-') and ':' not in repo and '@' not in repo, 'Local candidate repository required'
    assert re.fullmatch(r'webgpu-normal-' + stage + '-' + arch + r'-[0-9-]+\.service', unit), 'Unexpected stage unit'
    image, environment, driver = stage_inputs(source, output, repo, stage, arch, context, reference, variant)
    return launch_build(source, output, unit, image, arch, required_bytes, record, environment, driver)
