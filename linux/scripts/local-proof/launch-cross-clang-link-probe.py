#!/usr/bin/env python3
"""Run bounded observed linker diagnostics on the exact unverified prefix; neither mode qualifies a finished image."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import runpy
import shutil
import subprocess
import uuid
from pathlib import Path
from typing import TYPE_CHECKING

from proof_commands import checked_run

if TYPE_CHECKING:
    from proof_types import Json

LABEL = 'org.kataglyphis.cross-clang-link-diagnostic'


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + '\n')


def state(unit: str) -> dict[str, str]:
    raw = checked_run(['systemctl', '--user', 'show', unit, '--property=Id,LoadState,ActiveState,SubState,MainPID,Result,ExecMainStatus']).stdout
    return dict(line.split('=', 1) for line in raw.splitlines())


def validate(report: Json, mode: str) -> None:
    assert report['status'] == 'observed-cross-Clang-link-diagnostics-only' and report['mode'] == mode
    assert report['actual_backends']['returncode'] == 0 and set(report['actual_backends']['stdout'].split()) == {'X86', 'AArch64', 'RISCV', 'AMDGPU'}
    assert not report['environment'].get('LD_PRELOAD')
    records = report['records']
    assert len(records) == 6 and {(row['arch'], row['language']) for row in records} == {(arch, language) for arch in ['amd64', 'arm64', 'riscv64'] for language in ['c', 'cxx']}
    assert report['native_clang_sha256_before'] == report['native_clang_sha256_after']
    worker = runpy.run_path(str(Path(__file__).with_name('probe-cross-clang-link.py')))
    for row in records:
        worker['gnu_sysroot'](row['arch'], row['gcc_sysroot'])
        required = mode == 'gcc-sysroot' or row['arch'] == 'amd64'
        if required:
            assert row['minimal_link']['returncode'] == row['dynamic_link']['returncode'] == row['static_link']['returncode'] == 0
            assert isinstance(row['execution'], dict) and row['execution']['returncode'] == 0 and row['execution']['stdout'].strip() == '42'
        else:
            assert isinstance(row['minimal_link']['returncode'], int) and row['minimal_link']['returncode'] > 0
            assert not row['minimal_link']['timed_out'] and row['minimal_link']['stderr'].strip()


def launch(args: argparse.Namespace, parent: Json) -> None:
    out = args.directory
    assert not out.exists() and state(args.unit)['LoadState'] == 'not-found'
    engine = str(Path.home() / '.local/bin/nerdctl')
    image = parent['image_inspect']
    reference = image['RepoTags'][0]
    actual = json.loads(checked_run([engine, 'image', 'inspect', reference]).stdout)[0]
    assert actual['Id'] == image['Id'] and actual['RepoDigests'] == image['RepoDigests']
    assert not actual['Config'].get('Entrypoint')
    scripts = Path(__file__).resolve().parent
    out.mkdir(parents=True)
    (out / 'results').mkdir(mode=0o777)
    (out / 'results').chmod(0o777)
    (out / 'inputs').mkdir()
    for name in ['probe-cross-clang-link.py', 'probe-cross-clang-link.sh']:
        shutil.copyfile(scripts / name, out / name)
    for name in ['native-wrapper-probe.c', 'native-wrapper-probe.cc', 'cross-clang-link-minimal.c']:
        shutil.copyfile(scripts / name, out / 'inputs' / name)
    cleanup = scripts.parent / 'cleanup-owned-containers.py'
    token = uuid.uuid4().hex
    command = ['systemd-run', '--user', '--no-block', '--expand-environment=no', '--unit=' + args.unit]
    for setting in ['Type=oneshot', 'RemainAfterExit=yes', 'TimeoutStartSec=600', 'TimeoutStopSec=120', 'KillMode=control-group',
                    f'StandardOutput=append:{out}/unit.log', f'StandardError=append:{out}/unit.log',
                    f'ExecStopPost=/usr/bin/python3 {cleanup} --engine {engine} --owner-label {LABEL} --run-id {token} --cidfile {out}/container.cid --output {out}/retained-stop-cleanup.json --retain']:
        command += ['-p', setting]
    for setting in ['LC_ALL=C', f'HOME={Path.home()}', f'PATH={Path.home()}/.local/bin:/usr/local/bin:/usr/bin:/bin']:
        command += ['-E', setting]
    command += [engine, 'run', '--name', 'ant-' + args.unit.removesuffix('.service'), '--cidfile', str(out / 'container.cid'),
                '--label', LABEL + '=' + token, '--pull', 'never', '--init', '--security-opt', 'apparmor=unconfined',
                '--network', 'none', '--cpus', '2', '--memory', '2g', '--user', '0:0', '--env', 'LC_ALL=C',
                '-v', f'{out}/results:/evidence', '-v', f'{out}/inputs:/inputs:ro',
                '-v', f'{out}/probe-cross-clang-link.py:/probe.py:ro', '-v', f'{out}/probe-cross-clang-link.sh:/probe.sh:ro',
                reference, 'bash', '/probe.sh', '--output', '/evidence', '--mode', args.mode]
    record = {'unit': args.unit, 'mode': args.mode, 'run_id': token, 'image': reference, 'expected_config': actual['Id'],
              'expected_digests': actual['RepoDigests'], 'parent_proof_sha256': sha(args.prefix_proof),
              'command': command, 'created_at': datetime.datetime.now(datetime.UTC).isoformat(), 'scope': __doc__,
              'input_sha256': {str(path.relative_to(out)): sha(path) for path in [out / 'probe-cross-clang-link.py', out / 'probe-cross-clang-link.sh', *sorted((out / 'inputs').iterdir())]}}
    save(out / 'invocation.json', record)
    result = subprocess.run(command, text=True, capture_output=True, timeout=60, check=False)
    record.update(launch_status=result.returncode, stdout=result.stdout, stderr=result.stderr)
    save(out / 'invocation.json', record)
    assert result.returncode == 0
    print(json.dumps({'unit': args.unit, 'mode': args.mode, 'launch_status': result.returncode}))


def seal(args: argparse.Namespace, parent: Json) -> None:
    out = args.directory
    invocation = json.loads((out / 'invocation.json').read_text())
    assert invocation['mode'] == args.mode and invocation['unit'] == args.unit
    assert invocation['parent_proof_sha256'] == sha(args.prefix_proof)
    assert all(sha(out / name) == value for name, value in invocation['input_sha256'].items())
    terminal = state(args.unit)
    assert terminal['LoadState'] == 'loaded' and terminal['ActiveState'] == 'active' and terminal['SubState'] == 'exited'
    assert terminal['MainPID'] == terminal['ExecMainStatus'] == '0' and terminal['Result'] == 'success'
    engine = str(Path.home() / '.local/bin/nerdctl')
    cid = (out / 'container.cid').read_text().strip()
    actual = json.loads(checked_run([engine, 'inspect', cid]).stdout)[0]
    assert actual['Id'] == cid and actual['Config']['Labels'][LABEL] == invocation['run_id']
    assert not actual['State']['Running'] and actual['State']['ExitCode'] == 0
    assert any(value.endswith('@' + actual['Image']) for value in invocation['expected_digests'])
    report = json.loads((out / 'results/results.json').read_text())
    validate(report, args.mode)
    assert not (out / 'proof.json').exists()
    proof: Json = {'status': 'passed-actual-linker-diagnostic-control-only', 'mode': args.mode, 'terminal': terminal,
             'results_sha256': sha(out / 'results/results.json'), 'scope': __doc__, 'SDK_parent_qualified': False}
    save(out / 'proof.json', proof)
    checked_run(['systemctl', '--user', 'stop', args.unit])
    helper = Path(__file__).resolve().parent.parent / 'cleanup-owned-containers.py'
    checked_run(['python3', str(helper), '--engine', engine, '--owner-label', LABEL, '--run-id', invocation['run_id'],
                 '--cidfile', str(out / 'container.cid'), '--output', str(out / 'cleanup.json')])
    query = subprocess.run([engine, 'ps', '-a', '--format', '{{json .}}'], text=True, capture_output=True, timeout=60, check=False)
    save(out / 'independent-engine-query.json', {'returncode': query.returncode, 'stdout': query.stdout, 'stderr': query.stderr})
    assert query.returncode == 0 and invocation['run_id'] not in query.stdout and cid not in query.stdout
    proof.update(stopped=state(args.unit), cleanup=json.loads((out / 'cleanup.json').read_text()), owned_container_absent=True)
    assert proof['cleanup']['exit_status'] == 0 and proof['stopped']['MainPID'] == '0'
    save(out / 'proof-stopped.json', proof)
    print(json.dumps({'mode': args.mode, 'owned_container_absent': True, 'SDK_parent_qualified': False}))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['launch', 'seal'])
    parser.add_argument('--prefix-proof', required=True, type=Path)
    parser.add_argument('--directory', required=True, type=Path)
    parser.add_argument('--unit', required=True)
    parser.add_argument('--mode', choices=['baseline', 'gcc-sysroot'], required=True)
    args = parser.parse_args()
    args.directory = args.directory.resolve()
    assert args.unit.startswith('webgpu-cross-clang-link-probe-') and args.unit.endswith('.service')
    parent = json.loads(args.prefix_proof.read_text())
    assert parent['status'] == 'built-unverified-pre-smoke-component-only' and not parent['SDK_parent_qualified']
    {'launch': launch, 'seal': seal}[args.action](args, parent)


if __name__ == '__main__':
    main()
