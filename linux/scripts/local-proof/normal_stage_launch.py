"""Share ordinary local stage admission and transport; no image, cache or GPU acceptance."""

from __future__ import annotations

import datetime
import json
import re
import runpy
import subprocess
import sys
from pathlib import Path
from typing import TYPE_CHECKING

from proof_commands import checked_run

if TYPE_CHECKING:
    from proof_types import Json


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


def host_admission(unit: str, output: Path, image: str) -> Path:
    manager = dict(line.split('=', 1) for line in checked_run(['systemctl', '--user', 'show-environment']).stdout.splitlines() if '=' in line)
    assert not {key for key in manager if key.startswith('CROSS_') or key in {'ENABLE_AMD', 'ENABLE_NVIDIA', 'ENABLE_DEEPSTREAM', 'DRY_RUN'}}, 'Ambient build flags must be absent'
    assert checked_run(['systemctl', '--user', 'show', unit, '--property=LoadState', '--value']).stdout.strip() == 'not-found', 'Unit already exists'
    assert not output.exists(), 'Preserve existing stage output'
    temporary = Path.home() / '.cache' / unit.removesuffix('.service')
    assert not temporary.exists() and all(not (path / '.git').exists() for path in [temporary, *temporary.parents]), 'Temporary root must be fresh and outside Git'
    engine = str(Path.home() / '.local/bin/nerdctl')
    inventory = [json.loads(line) for line in checked_run([engine, 'images', '--format', '{{json .}}']).stdout.splitlines() if line.strip()]
    assert image not in {f"{row['Repository']}:{row['Tag']}" for row in inventory}, 'Preserve the existing image alias'
    assert not checked_run([engine, 'ps', '--format', '{{.ID}}']).stdout.strip(), 'Another container is running'
    processes = checked_run(['ps', '-eo', 'pid,args']).stdout.splitlines()
    assert not [line for line in processes if re.search(r'(?:nerdctl|buildctl)\S*\s+build\b|build-cross-chain\.sh', line)], 'Another build is running'
    return temporary


def launch_stage(source: Path, output: Path, unit: str, repo: str, stage: str, arch: str,
                 context: Path, reference: str, required_bytes: int, record: Json, variant: str = '') -> int:
    assert stage in {'sdk', 'gpu', 'media'} and variant in {'', 'rocm'}, 'Unreviewed stage profile'
    assert (stage in {'gpu', 'media'}) == bool(variant) and (stage == 'sdk' or arch == 'amd64'), 'Unreviewed GPU architecture'
    assert repo.startswith('ant-local/webgpu-') and ':' not in repo and '@' not in repo, 'Local candidate repository required'
    assert re.fullmatch(r'webgpu-normal-' + stage + '-' + arch + r'-[0-9-]+\.service', unit), 'Unexpected stage unit'
    image = checked_run(['bash', '-euo', 'pipefail', '-c',
                         '_TAG_NAMING_SH_LOADED=; source "$1"; IMAGE_REPO="$2"; CROSS_VARIANT="$3"; "$4" "$5"',
                         'normal-stage-tag', str(source / 'linux/scripts/01-core/tag-naming.sh'), repo, variant,
                         {'gpu':'cross_gpu_tag', 'sdk':'cross_sdk_tag', 'media':'cross_media_tag'}[stage], arch]).stdout.strip()
    temporary = host_admission(unit, output, image)
    sys.path.insert(0, str(source / 'linux/scripts'))
    disk = runpy.run_path(str(source / 'linux/scripts/launch-migraphx-configure-proof.py'))['require_build_disk'](output.parent)
    assert required_bytes >= 193273528320 and disk['available_bytes'] >= required_bytes, 'Unchanged disk reserve required'
    output.mkdir()
    temporary.mkdir(mode=0o700)
    engine = str(Path.home() / '.local/bin/nerdctl')
    command = ['systemd-run', '--user', '--no-block', '--expand-environment=no', f'--unit={unit}',
               '-p', 'Type=oneshot', '-p', 'RemainAfterExit=yes', '-p', 'TimeoutStartSec=21600', '-p', 'TimeoutStopSec=300',
               '-p', 'KillMode=control-group', '-p', f'WorkingDirectory={source}',
               '-p', f'StandardOutput=append:{output}/unit.log', '-p', f'StandardError=append:{output}/unit.log',
               '-E', 'LC_ALL=C', '-E', f'HOME={Path.home()}', '-E', f'PATH={Path.home()}/.local/bin:/usr/local/bin:/usr/bin:/bin',
               '-E', f'NERDCTL_BIN={engine}', '-E', 'BUILDKIT_PROGRESS=plain', '-E', f'BUILDKIT_CACHE_DIR={output}/buildcache',
               '-E', f'CROSS_{stage.upper()}_BASE_IMAGE={reference}', '-E', f'CROSS_{stage.upper()}_BASE_CONTEXT={context}', '-E', f'TMPDIR={temporary}']
    if variant:
        command += ['-E', f'CROSS_VARIANT={variant}']
    if stage == 'media':
        command += ['-E', 'ORT_WEB_REQUIRED=1', '-E', 'ORT_WASM_WEBGPU_FLAVORS=true']
    command += ['/bin/bash', str(source / 'linux/scripts/build-cross-stage.sh'), '--stage', stage, '--arch', arch,
                '--image-repo', repo, '--log-dir', str(output / 'logs')]
    record.update(created_at=datetime.datetime.now(datetime.UTC).isoformat(), unit=unit, source=str(source),
                  output=str(output), target_arch=arch, image=image, command=command, disk_admission=disk,
                  outlives_turn=True, publication=False)
    path = output / 'invocation.json'
    path.write_text(json.dumps(record, indent=2) + '\n')
    result = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
    record.update(launch_status=result.returncode, stdout=result.stdout, stderr=result.stderr)
    path.write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps({'unit':unit, 'launch_status':result.returncode, 'parent_manifest':record['parent_manifest'], 'disk':disk}))
    return result.returncode
