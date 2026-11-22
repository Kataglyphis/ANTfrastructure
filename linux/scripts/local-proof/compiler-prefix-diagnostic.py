#!/usr/bin/env python3
"""Export a failed compiler's pre-smoke prefix for diagnosis; this cannot qualify an SDK parent or final image."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import runpy
import shlex
import subprocess
import sys
from pathlib import Path
from typing import TYPE_CHECKING

from proof_commands import checked_run

if TYPE_CHECKING:
    from proof_types import Json

MARKER = 'LABEL kataglyphis.step=toolchain-smoke\n'
LABEL = 'org.kataglyphis.diagnostic'
VALUE = 'failed-compiler-before-required-smoke'


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + '\n')


def prefix(source: str) -> str:
    assert source.count(MARKER) == 1
    before, after = source.split(MARKER, 1)
    assert 'publish_llvm_target_ld_path' in after and 'smoke-toolchain.sh' in after
    assert 'LABEL kataglyphis.step=script-modes' in before
    return before + f'LABEL {LABEL}="{VALUE}"\n'


def command_for_prefix(argv: list[str], dockerfile: Path, image: str) -> list[str]:
    assert len(argv) > 8 and Path(argv[0]).name == 'nerdctl' and argv[1] == 'build'
    assert argv[-1] == '.' and '--pull=false' in argv
    assert not any(value.startswith(('--push', '--output', '--no-cache', '--target')) for value in argv)
    assert argv.count('-t') == argv.count('-f') == 1
    assert image.startswith('ant-local/') and 'unverified' in image and '@' not in image
    result = argv.copy()
    result[result.index('-f') + 1] = str(dockerfile)
    result[result.index('-t') + 1] = image
    return result


def state(unit: str) -> dict[str, str]:
    raw = checked_run(['systemctl', '--user', 'show', unit,
                       '--property=Id,LoadState,ActiveState,SubState,MainPID,Result,ExecMainStatus,ExecMainExitTimestampMonotonic']).stdout
    return dict(line.split('=', 1) for line in raw.splitlines())


def inventory(engine: str) -> list[Json]:
    raw = checked_run([engine, 'images', '--digests', '--no-trunc', '--format', '{{json .}}']).stdout
    return [json.loads(line) for line in raw.splitlines() if line.strip()]


def require_failure(plan: Json) -> dict[str, str]:
    actual = state(plan['unit'])
    assert actual['LoadState'] == 'loaded' and actual['MainPID'] == '0'
    assert actual['ActiveState'] == actual['SubState'] == 'failed'
    assert int(actual['ExecMainStatus']) > 0 and int(actual['ExecMainExitTimestampMonotonic']) > 0
    return actual


def prepare(args: argparse.Namespace, plan: Json) -> None:
    terminal = require_failure(plan)
    out, source = args.directory, Path(plan['source'])
    assert not out.exists()
    assert checked_run(['git', '-C', str(source), 'rev-parse', 'HEAD']).stdout.strip() == plan['source_revision']
    assert not checked_run(['git', '-C', str(source), 'status', '--porcelain']).stdout.strip()
    engine = str(Path.home() / '.local/bin/nerdctl')
    images = inventory(engine)
    names = {row['Repository'] + ':' + row['Tag'] for row in images}
    assert plan['local_image'] not in names and args.image not in names
    out.mkdir(parents=True)
    dockerfile = source / 'linux/Dockerfile.toolchain'
    (out / 'Dockerfile').write_text(prefix(dockerfile.read_text()))
    command = plan['command']
    environment = dict(os.environ)
    for index, value in enumerate(command[:-1]):
        if value == '-E':
            name, setting = command[index + 1].split('=', 1)
            environment[name] = setting
    environment.update(LC_ALL='C', RESOURCE_MONITOR='0', BUILDKIT_CACHE_DIR=str(out / 'buildcache'))
    renderer = command[command.index('/bin/bash'):].copy() + ['--dry-run']
    renderer[renderer.index('--log-dir') + 1] = str(out / 'render-logs')
    result = subprocess.run(renderer, env=environment, text=True, capture_output=True, timeout=120, check=False)
    (out / 'render.stdout').write_text(result.stdout)
    (out / 'render.stderr').write_text(result.stderr)
    assert result.returncode == 0
    lines = [line.removeprefix('[DRY RUN] ') for line in result.stdout.splitlines() if line.startswith('[DRY RUN] ')]
    assert len(lines) == 1 and "$'" not in lines[0]
    build = command_for_prefix(shlex.split(lines[0]), out / 'Dockerfile', args.image)
    log = Path(plan['output']) / 'logs/compiler.log'
    record = {'status': 'prepared-unverified-diagnostic-component-only', 'prepared_at': datetime.datetime.now(datetime.UTC).isoformat(),
              'source': str(source), 'source_revision': plan['source_revision'], 'failed_unit': plan['unit'], 'failed_terminal': terminal,
              'failed_image_absent': True, 'failed_log': str(log), 'failed_log_sha256': digest(log), 'failed_plan_sha256': digest(args.failed_plan),
              'original_Dockerfile_sha256': digest(dockerfile), 'diagnostic_Dockerfile_sha256': digest(out / 'Dockerfile'),
              'command': build, 'unit': args.unit, 'image': args.image, 'engine': engine, 'scope': __doc__, 'publication': False}
    save(out / 'prepared.json', record)
    print(json.dumps({'status': record['status'], 'failed_image_absent': True, 'source': record['source_revision']}))


def launch(args: argparse.Namespace, plan: Json) -> None:
    out = args.directory
    record = json.loads((out / 'prepared.json').read_text())
    assert require_failure(plan) == record['failed_terminal']
    assert record['failed_plan_sha256'] == digest(args.failed_plan)
    assert digest(Path(plan['source']) / 'linux/Dockerfile.toolchain') == record['original_Dockerfile_sha256']
    assert digest(out / 'Dockerfile') == record['diagnostic_Dockerfile_sha256']
    assert (out / 'Dockerfile').read_text() == prefix((Path(plan['source']) / 'linux/Dockerfile.toolchain').read_text())
    assert command_for_prefix(record['command'], out / 'Dockerfile', args.image) == record['command']
    assert args.unit == record['unit'] and args.image == record['image']
    assert state(args.unit)['LoadState'] == 'not-found' and not (out / 'invocation.json').exists()
    assert args.image not in {row['Repository'] + ':' + row['Tag'] for row in inventory(record['engine'])}
    scripts = Path(plan['source']) / 'linux/scripts'
    sys.path.insert(0, str(scripts))
    disk = runpy.run_path(str(scripts / 'launch-migraphx-configure-proof.py'))['require_build_disk'](out.parent)
    assert disk['available_bytes'] >= 193273528320
    temporary = Path.home() / '.cache' / args.unit.removesuffix('.service')
    assert not temporary.exists() and not any((path / '.git').exists() for path in [temporary, *temporary.parents])
    temporary.mkdir(mode=0o700)
    command = ['systemd-run', '--user', '--no-block', '--expand-environment=no', '--unit=' + args.unit]
    for setting in ['Type=oneshot', 'RemainAfterExit=yes', 'TimeoutStartSec=7200', 'TimeoutStopSec=300', 'KillMode=control-group',
                    'WorkingDirectory=' + plan['source'], f'StandardOutput=append:{out}/unit.log', f'StandardError=append:{out}/unit.log']:
        command += ['-p', setting]
    for setting in ['LC_ALL=C', f'HOME={Path.home()}', f'TMPDIR={temporary}', f'PATH={Path.home()}/.local/bin:/usr/local/bin:/usr/bin:/bin']:
        command += ['-E', setting]
    command += record['command']
    invocation = {'unit': args.unit, 'command': command, 'prepared_sha256': digest(out / 'prepared.json'), 'disk_admission': disk, 'scope': __doc__}
    save(out / 'invocation.json', invocation)
    result = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
    invocation.update(launch_status=result.returncode, stdout=result.stdout, stderr=result.stderr)
    save(out / 'invocation.json', invocation)
    assert result.returncode == 0
    print(json.dumps({'unit': args.unit, 'launch_status': result.returncode, 'disk': disk}))


def seal(args: argparse.Namespace, plan: Json) -> None:
    out = args.directory
    record = json.loads((out / 'prepared.json').read_text())
    terminal = state(args.unit)
    assert terminal['LoadState'] == 'loaded' and terminal['ActiveState'] == 'active' and terminal['SubState'] == 'exited'
    assert terminal['MainPID'] == terminal['ExecMainStatus'] == '0' and terminal['Result'] == 'success'
    image = json.loads(checked_run([record['engine'], 'image', 'inspect', args.image]).stdout)[0]
    assert image['Config']['Labels'][LABEL] == VALUE and image['Architecture'] == 'amd64'
    assert plan['local_image'] not in {row['Repository'] + ':' + row['Tag'] for row in inventory(record['engine'])}
    assert not (out / 'proof.json').exists()
    proof = {'status': 'built-unverified-pre-smoke-component-only', 'terminal': terminal, 'image_inspect': image,
             'prepared_sha256': digest(out / 'prepared.json'), 'normal_failed_image_absent': True,
             'SDK_parent_qualified': False, 'scope': __doc__}
    save(out / 'proof.json', proof)
    checked_run(['systemctl', '--user', 'stop', args.unit])
    proof['stopped'] = state(args.unit)
    assert proof['stopped']['MainPID'] == '0' and proof['stopped']['ActiveState'] == 'inactive'
    save(out / 'proof-stopped.json', proof)
    print(json.dumps({'status': proof['status'], 'image': args.image, 'stopped': True}))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'launch', 'seal'])
    parser.add_argument('--failed-plan', type=Path, required=True)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--unit', required=True)
    parser.add_argument('--image', required=True)
    args = parser.parse_args()
    args.directory = args.directory.resolve()
    assert re.fullmatch(r'webgpu-compiler-prefix-diagnostic-[A-Za-z0-9_.-]+\.service', args.unit)
    plan = json.loads(args.failed_plan.read_text())
    {'prepare': prepare, 'launch': launch, 'seal': seal}[args.action](args, plan)


if __name__ == '__main__':
    main()
