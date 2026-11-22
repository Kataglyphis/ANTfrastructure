#!/usr/bin/env python3
"""Replay source wrapper selection on a preserved old compiler, retaining missing-backend refusals; no fresh compiler or SDK acceptance."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import re
import shlex
import shutil
import subprocess
import uuid
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('action', choices=['launch', 'seal'])
for name in ['snapshot-invocation', 'parent-plan', 'parent-proof', 'output']:
    parser.add_argument('--' + name, type=Path, required=True)
parser.add_argument('--unit', required=True)
args = parser.parse_args()
engine = str(Path.home() / '.local/bin/nerdctl')
label = 'org.kataglyphis.native-clang-wrapper-replay'
tools_dir = Path(__file__).resolve().parent
out = args.output.resolve()
snapshot = json.loads(args.snapshot_invocation.read_text())
source = Path(snapshot['source'])
parent_plan = json.loads(args.parent_plan.read_text())
parent = json.loads(args.parent_proof.read_text())
assert parent['status'] == 'passed-qualified-native-compiler-OCI-and-base-ancestry'
assert parent['source_revision'] == parent_plan['source_revision']
assert snapshot['owner_label'] == 'org.kataglyphis.migraphx-source'
assert re.fullmatch(r'webgpu-native-clang-wrapper-replay-[A-Za-z0-9_.-]+\.service', args.unit)
cleanup = source / 'linux/scripts/cleanup-owned-containers.py'

def run(command: list[str]) -> str:
    return subprocess.check_output(command, text=True, timeout=60)

def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + '\n')

def sha(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def state() -> dict[str, str]:
    raw = run(['systemctl', '--user', 'show', args.unit, '--property=Id,LoadState,ActiveState,SubState,MainPID,ExecMainStatus,Result'])
    return dict(line.split('=', 1) for line in raw.splitlines() if '=' in line)

if args.action == 'launch':
    assert state()['LoadState'] == 'not-found' and not out.exists()
    image = json.loads(run([engine, 'image', 'inspect', parent_plan['local_image']]))[0]
    assert image['Architecture'] == 'amd64' and image['Id'] == parent['config']
    assert any(value.endswith('@' + parent['manifest']) for value in image['RepoDigests'])
    assert not image['Config'].get('Entrypoint')
    run(['python3', str(cleanup), '--help'])
    out.mkdir()
    (out / 'results').mkdir()
    (out / 'inputs').mkdir()
    shutil.copyfile(tools_dir / 'replay-native-clang-wrappers.sh', out / 'replay.sh')
    for name, target in [('native-wrapper-probe.c', 'native.c'), ('native-wrapper-probe.cc', 'native.cc')]:
        shutil.copyfile(tools_dir / name, out / 'inputs' / target)
    token = uuid.uuid4().hex
    stop_command = ['python3', str(cleanup), '--engine', engine, '--owner-label', label, '--run-id', token,
                    '--cidfile', str(out / 'container.cid'), '--output', str(out / 'retained-stop-cleanup.json'), '--retain']
    command = ['systemd-run', '--user', '--no-block', '--expand-environment=no', '--unit=' + args.unit]
    for setting in ['Type=oneshot', 'RemainAfterExit=yes', 'TimeoutStartSec=600', 'TimeoutStopSec=120', 'KillMode=control-group',
                    f'StandardOutput=append:{out}/stdout.log', f'StandardError=append:{out}/stderr.log', 'ExecStopPost=' + shlex.join(stop_command)]:
        command += ['-p', setting]
    for value in ['LC_ALL=C', f'HOME={Path.home()}', f'PATH={Path.home()}/.local/bin:/usr/local/bin:/usr/bin:/bin']:
        command += ['-E', value]
    command += [engine, 'run', '--name', 'ant-' + args.unit.removesuffix('.service'), '--cidfile', str(out / 'container.cid'), '--label', f'{label}={token}',
                '--pull', 'never', '--init', '--security-opt', 'apparmor=unconfined', '--network', 'none', '--cpus', '2', '--memory', '2g', '--user', '0:0', '--env', 'LC_ALL=C',
                '-v', f'{source}:/candidate:ro', '-v', f'{out}/results:/evidence', '-v', f'{out}/inputs:/inputs:ro', '-v', f'{out}/replay.sh:/replay.sh:ro',
                parent_plan['local_image'], 'bash', '/replay.sh', parent_plan['expected_pins']['LLVM_RELEASE']]
    record = {'created_at': datetime.datetime.now(datetime.UTC).isoformat(), 'unit': args.unit, 'owner_label': label, 'run_id': token,
              'source_snapshot': str(source), 'source_parent_revision': snapshot['head'], 'source_patch_sha256': snapshot['patch_sha256'],
              'expected_manifest': parent['manifest'], 'expected_config': parent['config'], 'command': command,
              'scope': __doc__, 'publication': False, 'input_sha256': {'replay.sh': sha(out / 'replay.sh'), 'inputs/native.c': sha(out / 'inputs/native.c'), 'inputs/native.cc': sha(out / 'inputs/native.cc')},
              'candidate_sha256': {name: sha(source / name) for name in ['linux/scripts/02-toolchain/llvm.sh', 'linux/scripts/02-toolchain/llvm-cross.sh']}}
    save(out / 'invocation.json', record)
    launched = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
    record.update(launch_status=launched.returncode, stdout=launched.stdout, stderr=launched.stderr)
    save(out / 'invocation.json', record)
    print(json.dumps({'unit': args.unit, 'launch_status': launched.returncode, 'expected_manifest': parent['manifest']}))
    raise SystemExit(launched.returncode)

inv = json.loads((out / 'invocation.json').read_text())
assert inv['unit'] == args.unit and inv['owner_label'] == label and inv['source_snapshot'] == str(source)
terminal = state()
assert terminal['LoadState'] == 'loaded' and terminal['ActiveState'] == 'active' and terminal['SubState'] == 'exited'
assert terminal['MainPID'] == terminal['ExecMainStatus'] == '0' and terminal['Result'] == 'success'
cid = (out / 'container.cid').read_text().strip()
container = json.loads(run([engine, 'inspect', cid]))[0]
save(out / 'container-inspect.json', container)
assert container['Id'] == cid and container['Image'] == inv['expected_manifest']
assert container['Config']['Labels'][label] == inv['run_id'] and container['State']['ExitCode'] == 0 and not container['State']['Running']
assert not container['HostConfig'].get('Privileged', False)
assert all(sha(out / name) == value for name, value in inv['input_sha256'].items())
assert all(sha(source / name) == value for name, value in inv['candidate_sha256'].items())
results = out / 'results'
assert (results / 'result.txt').read_text().strip() == 'passed-old-compiler-native-wrapper-replay-only'
assert (results / 'original-wrapper.status').read_text().strip() == '127'
assert (results / 'original-targets-built.txt').read_text().split() == ['X86']
assert (results / 'native-clang-before.sha256').read_bytes() == (results / 'native-clang-after.sha256').read_bytes()
for name in ['native-c', 'native-cxx']:
    assert (results / (name + '.result')).read_text().strip() == '42'
    assert 'Advanced Micro Devices X86-64' in (results / (name + '.elf')).read_text()
for driver in ['clang', 'clang++']:
    for target in ['amd64', 'arm64', 'riscv64']:
        assert f'exec "/opt/llvm-target-amd64/bin/{driver}"' in (results / f'candidate-{driver}-{target}.sh').read_text()
    for target in ['arm64', 'riscv64']:
        assert (results / f'{driver}-{target}.negative.status').read_text().strip() == '1'
proof = {'status': 'passed-real-native-wrapper-repair-on-old-compiler-only', 'observed_at': datetime.datetime.now(datetime.UTC).isoformat(),
         'terminal_before_stop': terminal, 'actual_image_manifest': container['Image'], 'source_patch_sha256': inv['source_patch_sha256'],
         'original_wrapper_status': 127, 'native_C_and_Cxx_link_and_execution': True, 'old_foreign_backend_refusals': 4,
         'old_native_backends': ['X86'], 'fresh_all_target_compiler_required': True, 'SDK_accepted': False, 'scope': __doc__,
         'results_sha256': {path.name: sha(path) for path in results.iterdir() if path.is_file()}, 'publication': False}
assert not (out / 'proof.json').exists()
save(out / 'proof.json', proof)
run(['systemctl', '--user', 'stop', args.unit])
after = state()
assert after['ActiveState'] == 'inactive' and after['MainPID'] == '0'
retained = json.loads((out / 'retained-stop-cleanup.json').read_text())
assert retained['exit_status'] == 0 and retained['retain']
run(['python3', str(cleanup), '--engine', engine, '--owner-label', label, '--run-id', inv['run_id'], '--cidfile', str(out / 'container.cid'), '--output', str(out / 'cleanup.json')])
cleaned = json.loads((out / 'cleanup.json').read_text())
assert cleaned['exit_status'] == 0
raw = run([engine, 'ps', '-a', '--format', '{{json .}}'])
save(out / 'independent-engine-query.json', {'returncode': 0, 'stdout': raw})
assert not any(inv['run_id'] in json.dumps(row) or cid.startswith(row['ID']) or row['ID'].startswith(cid) for row in [json.loads(line) for line in raw.splitlines() if line.strip()])
proof.update(stopped=after, cleanup_exit_status=0, independent_engine_query_exit_status=0, owned_container_absent=True)
save(out / 'proof-stopped.json', proof)
print(json.dumps({key: proof[key] for key in ['status', 'original_wrapper_status', 'old_foreign_backend_refusals', 'owned_container_absent']}))
