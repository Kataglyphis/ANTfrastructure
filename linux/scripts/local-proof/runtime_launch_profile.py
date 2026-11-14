"""Prepare the ordinary ROCm runtime from actual native Android; no registry publication, licence, hardware or FINAL acceptance."""

from __future__ import annotations

import json
import re
import subprocess
import uuid
from pathlib import Path
from typing import TYPE_CHECKING

from native_oci_layout import sha
from normal_stage_launch import downstream_record, launch_build
from proof_commands import checked_run
from runtime_source_profile import select_runtime_source

if TYPE_CHECKING:
    from proof_types import Json


def local_reference(actual: Json) -> str:
    assert actual['image'].startswith('ant-local/webgpu-'), 'Reviewed local Android image required'
    assert re.fullmatch(r'sha256:[0-9a-f]{64}', actual['manifest']) and re.fullmatch(r'sha256:[0-9a-f]{64}', actual['config']), 'Exact Android manifest/config required'
    return 'docker.io/' + actual['image'].rsplit(':', 1)[0] + '@' + actual['manifest']


def alias_inventory(engine: str, reference: str) -> list[Json]:
    rows = [json.loads(line) for line in checked_run([engine, 'images', '--format', '{{json .}}']).stdout.splitlines() if line.strip()]
    return [row for row in rows if row['Name'] == reference]


def prepare_local_alias(actual: Json, path: Path) -> Json:
    assert not path.exists() and not path.is_symlink(), 'Preserve prior local alias evidence'
    engine = str(Path.home() / '.local/bin/nerdctl')
    reference = local_reference(actual)
    record: Json = {'status': 'local-alias-preparation-started', 'reference': reference, 'actual_image': actual,
                    'publication': False, 'scope': 'Local immutable metadata only; no registry availability or image acceptance.'}
    path.write_text(json.dumps(record, indent=2) + '\n')
    rows = alias_inventory(engine, reference)
    assert len(rows) <= 1, 'Local immutable alias is ambiguous'
    if rows:
        assert rows[0]['Digest'] == actual['manifest'] and rows[0]['Platform'] == 'linux/amd64', 'Preserve a foreign existing alias'
        record['created'] = False
    else:
        command = [engine, 'image', 'tag', actual['image'], reference]
        result = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
        record.update(command=command, tag_status=result.returncode, stdout=result.stdout, stderr=result.stderr)
        path.write_text(json.dumps(record, indent=2) + '\n')
        assert result.returncode == 0, 'Local immutable alias creation failed'
        record['created'] = True
    rows = alias_inventory(engine, reference)
    assert len(rows) == 1 and rows[0]['Digest'] == actual['manifest'] and rows[0]['Platform'] == 'linux/amd64', 'Local immutable alias differs'
    resolved = json.loads(checked_run([engine, 'image', 'inspect', actual['manifest']]).stdout)
    assert len(resolved) == 1 and resolved[0]['Id'] == actual['config'], 'Local immutable alias config differs'
    assert {value.rsplit('@', 1)[1] for value in resolved[0]['RepoDigests']} == {actual['manifest']}, 'Local immutable manifest differs'
    record.update(status='prepared-verified-local-immutable-alias-only', inventory=rows)
    path.write_text(json.dumps(record, indent=2) + '\n')
    return {'local_immutable_alias': record, 'local_alias_receipt_sha256': sha(path)}


def runtime_tags(source: Path, prefix: str) -> tuple[str, ...]:
    command = ['bash', '-euo', 'pipefail', '-c',
               '_TAG_NAMING_SH_LOADED=; source "$1"; RUNTIME_IMAGE_PREFIX="$2"; for fn in runtime_base_tag runtime_package_tag runtime_wrapper_tag; do "$fn" amd64; printf "\\n"; done',
               'normal-runtime-tags', str(source / 'linux/scripts/01-core/tag-naming.sh'), prefix]
    values = tuple(checked_run(command).stdout.splitlines())
    assert len(values) == len(set(values)) == 3, 'Canonical runtime tags must be distinct'
    return values


def launch_runtime(plan: Json, invocation: Json, invocation_path: Path, parent: Json, context: Path,
                   proof_path: Path, output: Path, unit: str, prefix: str, app_ref: str, *,
                   selected_source: Path | None = None, source_proof: Path | None = None) -> int:
    assert re.fullmatch(r'webgpu-normal-runtime-amd64-[0-9-]+\.service', unit), 'Unexpected runtime producer unit'
    assert re.fullmatch(r'ant-local/webgpu-[a-z0-9][a-z0-9-]*:runtime-rocm-[A-Za-z0-9][A-Za-z0-9_.-]{0,90}', prefix), 'Fresh local ROCm runtime prefix required'
    assert re.fullmatch(r'[0-9a-f]{40}', app_ref), 'Runtime app ref must be one exact commit'
    assert context.name.endswith('-amd64'), 'Native Android context must retain the runtime architecture suffix'
    host_root = Path(__file__).resolve().parents[3]
    assert not checked_run(['git', '-C', str(host_root), 'status', '--porcelain']).stdout.strip(), 'Commit host tools before runtime launch'
    source, review = select_runtime_source(invocation, selected_source, source_proof)
    images = runtime_tags(source, prefix)
    actual = {'image': invocation['image'], 'manifest': parent['manifest'], 'config': parent['config']}
    reference = local_reference(actual)
    scripts = Path(__file__).resolve().parent.parent
    run_id, owner_label = uuid.uuid4().hex, 'org.kataglyphis.normal-runtime'
    engine = str(Path.home() / '.local/bin/nerdctl')
    wrapper = str(scripts / 'owned-nerdctl.py')
    cleanup = ['python3', str(scripts / 'cleanup-owned-containers.py'), '--engine', engine, '--owner-label', owner_label,
               '--run-id', run_id, '--cidfile', str(output / 'container.cid'), '--output', str(output / 'cleanup.json')]
    environment = ['CROSS_VARIANT=rocm', 'CROSS_NO_PUSH=1', 'ENABLE_AMD=true', 'ENABLE_NVIDIA=false', 'ENABLE_DEEPSTREAM=false',
                   'ENABLE_TENSORRT=false', 'ENABLE_ROCM_ASAN=false', 'BUILD_TYPE=Release', 'TORCH_APP_MODE=all',
                   'ONNX_PACKAGE=onnxruntime', 'PYTORCH_EXTRA=pytorch-rocm10', 'APP_REF=' + app_ref,
                   'ARTIFACT_CONTEXT_MODE=oci', 'ARTIFACT_CONTEXT_ROOT=' + str(context).removesuffix('-amd64'),
                   'RUNTIME_ANDROID_PIN_amd64=' + reference, 'RUNTIME_WHEELS_SOURCE=image', 'RUNTIME_USE_LOCAL_CONTEXT_CHAIN=true',
                   'RUNTIME_CONTEXT_ROOT=' + str(output / 'runtime-contexts'), 'LOG_DIR=' + str(output / 'logs'),
                   'RUNTIME_REUSE_CHILDREN=0', 'RUNTIME_IMAGE_SMOKE=1', 'RUNTIME_INPUT_PREFLIGHT=1',
                   'WRAPPER_CONTENT_GATE=1', 'ANCESTRY_STAMP_ENFORCE=1', 'CROSS_RUN_ID=runtime-' + run_id,
                   'ANT_RUNTIME_ENGINE=' + engine, 'ANT_RUNTIME_OWNER_LABEL=' + owner_label, 'ANT_RUNTIME_RUN_ID=' + run_id]
    driver = ['/bin/bash', str(source / 'linux/scripts/build-runtime-manifest.sh'), '--image', prefix, '--target-arches', 'amd64',
              '--artifact-image-prefix', invocation['image'].removesuffix('-amd64'), '--artifact-build-mode', 'cross', '--skip-manifest']
    record = downstream_record(invocation, invocation_path, proof_path, parent, 'Android')
    if review is not None:
        record.update(source_revision=review['runtime_source_revision'],
                      source_full_preflight_proof=review['runtime_full_source_proof'],
                      source_full_preflight_sha256=review['runtime_full_source_proof_sha256'],
                      runtime_source_selection=review)
    record.update(stage='runtime', variant='rocm', image_prefix=prefix, app_ref=app_ref, Android_layers_rehashed=parent['layers'],
                  Media_layers_matched=parent['matched_Media_layers_and_diffIDs'], host_tools_revision=checked_run(['git', '-C', str(host_root), 'rev-parse', 'HEAD']).stdout.strip(),
                  selected_host_workers_sha256={str(path): sha(path) for path in [Path(__file__), Path(__file__).with_name('launch-normal-runtime.py'),
                      Path(__file__).with_name('normal_stage_launch.py'), Path(__file__).with_name('android_handoff_profile.py'),
                      Path(__file__).with_name('runtime_source_profile.py'),
                      scripts / 'owned-nerdctl.py', scripts / 'owned_nerdctl_args.py', scripts / 'owned_containers.py',
                      scripts / 'cleanup-owned-containers.py', scripts / 'host_commands.py']},
                  run_id=run_id, owner_label=owner_label, expected_runtime_run_id='runtime-' + run_id,
                  engine=engine, engine_wrapper=wrapper, cleanup_command=cleanup,
                  GPU_or_FINAL_acceptance=False, scope=__doc__)
    return launch_build(source, output, unit, images[-1], 'amd64', plan['required_bytes'], record, environment, driver,
                        images=images, prepare=lambda: prepare_local_alias(actual, output / 'local-alias.json'),
                        engine_path=wrapper, cleanup=cleanup)
