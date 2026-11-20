#!/usr/bin/env python3
"""Run and seal actual SDK LLVM materialization on the qualified parent; no completed SDK or GPU acceptance."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import shutil
import subprocess
import uuid
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from proof_types import Json

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('action', choices=['launch', 'seal'])
parser.add_argument('--source', required=True, type=Path)
parser.add_argument('--plan', required=True, type=Path)
parser.add_argument('--parent-proof', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--arch', required=True, choices=['amd64', 'arm64', 'riscv64'])
parser.add_argument('--unit', required=True)
parser.add_argument('--plain-load-probe', type=Path, required=True)
args = parser.parse_args()
source = args.source.resolve()
out = args.output.resolve()
engine = str(Path.home() / '.local/bin/nerdctl')
label = 'org.kataglyphis.sdk-llvm-materialization'
tool_dir = Path(__file__).resolve().parent

def run(command: list[str]) -> str:
    return subprocess.run(command, capture_output=True, text=True, check=True, timeout=60).stdout

def save(path: Path, data: Json) -> None:
    path.write_text(json.dumps(data, indent=2) + '\n')

def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

def state() -> dict[str, str]:
    text = run(['systemctl', '--user', 'show', args.unit, '--property=Id,LoadState,ActiveState,SubState,MainPID,Result,ExecMainStatus'])
    return dict(line.split('=', 1) for line in text.splitlines())

plan = json.loads(args.plan.read_text())
parent = json.loads(args.parent_proof.read_text())
assert parent['status'] == 'passed-qualified-native-compiler-OCI-and-base-ancestry'
assert parent['source_revision'] == plan['source_revision']
revision = run(['git', '-C', str(source), 'rev-parse', 'HEAD']).strip()
assert not run(['git', '-C', str(source), 'status', '--porcelain']).strip()
assert (source / 'linux/scripts/01-core/versions.env').read_bytes() == (Path(plan['source']) / 'linux/scripts/01-core/versions.env').read_bytes()
assert args.unit.startswith('webgpu-sdk-llvm-materialization-') and args.unit.endswith('.service')
cleanup = source / 'linux/scripts/cleanup-owned-containers.py'
if args.action == 'launch':
    assert state()['LoadState'] == 'not-found' and not out.exists()
    image = json.loads(run([engine, 'image', 'inspect', plan['local_image']]))[0]
    assert image['Architecture'] == 'amd64'
    assert image['Id'] == parent['config'] and any(value.endswith('@' + parent['manifest']) for value in image['RepoDigests'])
    assert not image['Config'].get('Entrypoint')
    run(['python3', str(cleanup), '--help'])
    out.mkdir()
    (out / 'results').mkdir()
    for name in ['replay-sdk-llvm-materialization.sh', 'qualify-compiler-image.sh']:
        shutil.copyfile(tool_dir / name, out / name)
    shutil.copyfile(source / 'linux/scripts/02-toolchain/materialize-llvm-target.sh', out / 'candidate-materializer.sh')
    shutil.copyfile(args.plain_load_probe, out / 'plain-load.py')
    token = uuid.uuid4().hex
    stop = f'ExecStopPost=/usr/bin/python3 {cleanup} --engine {engine} --owner-label {label} --run-id {token} --cidfile {out}/container.cid --output {out}/retained-stop-cleanup.json --retain'
    command = ['systemd-run', '--user', '--no-block', '--expand-environment=no', f'--unit={args.unit}',
               '-p', 'Type=oneshot', '-p', 'RemainAfterExit=yes', '-p', 'TimeoutStartSec=600', '-p', 'TimeoutStopSec=120',
               '-p', 'KillMode=control-group', '-p', f'StandardOutput=append:{out}/stdout.log', '-p', f'StandardError=append:{out}/stderr.log', '-p', stop,
               '-E', 'LC_ALL=C', '-E', f'HOME={Path.home()}', '-E', f'PATH={Path.home()}/.local/bin:/usr/local/bin:/usr/bin:/bin',
               engine, 'run', '--name', 'ant-' + args.unit.removesuffix('.service'), '--cidfile', str(out / 'container.cid'), '--label', f'{label}={token}',
               '--pull', 'never', '--init', '--security-opt', 'apparmor=unconfined', '--network', 'none', '--cpus', '2', '--memory', '2g', '--user', '0:0', '--env', 'LC_ALL=C',
               '-v', f'{out}/results:/evidence', '-v', f'{out}/candidate-materializer.sh:/candidate-materializer.sh:ro',
               '-v', f'{out}/replay-sdk-llvm-materialization.sh:/replay.sh:ro', '-v', f'{out}/qualify-compiler-image.sh:/qualify.sh:ro',
               '-v', f'{out}/plain-load.py:/plain-load.py:ro', '-v', f'{source}/linux/scripts/01-core:/opt/scripts/core:ro',
               plan['local_image'], 'bash', '/replay.sh', args.arch, plan['expected_pins']['GCC_VERSION'], plan['expected_pins']['LLVM_RELEASE']]
    record = {'created_at': datetime.datetime.now(datetime.UTC).isoformat(), 'unit': args.unit, 'source': str(source), 'source_revision': revision,
              'parent_source_revision': plan['source_revision'], 'expected_manifest': parent['manifest'], 'expected_config': parent['config'],
              'owner_label': label, 'run_id': token, 'target_arch': args.arch, 'host_arch': 'amd64', 'command': command,
              'input_sha256': {p.name: sha(p) for p in out.iterdir() if p.is_file()}, 'scope': __doc__, 'publication': False}
    save(out / 'invocation.json', record)
    result = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
    record.update(launch_status=result.returncode, stdout=result.stdout, stderr=result.stderr)
    save(out / 'invocation.json', record)
    print(json.dumps({'unit': args.unit, 'launch_status': result.returncode, 'target': args.arch}))
    raise SystemExit(result.returncode)

inv = json.loads((out / 'invocation.json').read_text())
assert inv['unit'] == args.unit and inv['source_revision'] == revision and inv['target_arch'] == args.arch and inv['owner_label'] == label
terminal = state()
assert terminal['LoadState'] == 'loaded' and terminal['ActiveState'] == 'active' and terminal['SubState'] == 'exited'
assert terminal['MainPID'] == terminal['ExecMainStatus'] == '0' and terminal['Result'] == 'success'
cid = (out / 'container.cid').read_text().strip()
container = json.loads(run([engine, 'inspect', cid]))[0]
save(out / 'container-inspect.json', container)
assert container['Id'] == cid and container['Image'] == inv['expected_manifest']
assert container['Config']['Labels'][label] == inv['run_id']
assert not container['State']['Running'] and container['State']['ExitCode'] == 0
assert not container['HostConfig'].get('Privileged', False)
results = out / 'results'
for name in ['host', 'target']:
    assert (results / f'{name}-clang-before.sha256').read_text().split()[0] == (results / f'{name}-clang-after.sha256').read_text().split()[0]
expected_native = '/opt/llvm-target' if args.arch == 'amd64' else '/opt/llvm-target-amd64'
expected_prefixes = sorted({'llvm-target-amd64', 'llvm-target-' + args.arch})
assert (results / 'architecture-prefixes.txt').read_text().splitlines() == expected_prefixes
machine = {'amd64': 'Advanced Micro Devices X86-64', 'arm64': 'AArch64', 'riscv64': 'RISC-V'}[args.arch]
assert any(line.partition(':')[0].strip() == 'Machine' and line.partition(':')[2].strip() == machine
           for line in (results / 'target-elf-header.txt').read_text().splitlines())
modes = {}
for stem in ['', 'login-']:
    native, defaults, loaded = [json.loads((results / f'{stem}{name}.json').read_text()) for name in ['native', 'defaults', 'loaded']]
    assert native['status'] == 'passed-native-llvm-tool-and-loader-selection-only'
    assert native['facts']['native_prefix'] == expected_native and native['facts']['native_tool_count'] == 157
    assert native['facts']['llvm_config_version'] == plan['expected_pins']['LLVM_RELEASE']
    assert all(row['dynamic']['returncode'] == 0 and row['source'] == row['cache_winner'] for row in native['libraries'])
    assert defaults['status'] == 'passed-installed-amd64-compiler-defaults-only'
    assert all(defaults['facts'][name]['version'] == plan['expected_pins']['GCC_VERSION'] for name in ['cc', 'c++', 'gcc', 'g++'])
    assert all(defaults['facts'][name]['version'] == plan['expected_pins']['LLVM_RELEASE'] for name in ['clang', 'clang++'])
    assert loaded['status'] == 'passed-bare-soname-mapping-only' and len(loaded['loaded']) == 1
    assert loaded['loaded'][0]['path'].startswith(expected_native + '/lib/')
    assert loaded['loaded'][0]['sha256'] == (results / f'{stem}source-library-sha256.txt').read_text().split()[0]
    modes[stem or 'default'] = {'native': native['facts'], 'defaults': defaults['facts'], 'loaded': loaded}
assert all(sha(out / name) == digest for name, digest in inv['input_sha256'].items())
assert (out / 'candidate-materializer.sh').read_bytes() == (source / 'linux/scripts/02-toolchain/materialize-llvm-target.sh').read_bytes()
proof = {'status': 'passed-real-parent-image-SDK-LLVM-materialization-only', 'observed_at': datetime.datetime.now(datetime.UTC).isoformat(),
         'source_revision': revision, 'parent_source_revision': inv['parent_source_revision'], 'terminal': terminal,
         'actual_container_id': cid, 'actual_image_manifest': container['Image'], 'target_arch': args.arch,
         'native_selection': modes, 'target_machine': machine, 'host_and_target_clang_bytes_preserved': True,
         'source_script_sha256': inv['input_sha256']['candidate-materializer.sh'], 'scope': __doc__, 'publication': False,
         'results_sha256': {p.name: sha(p) for p in results.iterdir() if p.is_file()}}
assert not (out / 'proof.json').exists()
save(out / 'proof.json', proof)
run(['systemctl', '--user', 'stop', args.unit])
assert state()['ActiveState'] == 'inactive' and state()['MainPID'] == '0'
retained = json.loads((out / 'retained-stop-cleanup.json').read_text())
assert retained['exit_status'] == 0 and retained['retain'] is True
run(['python3', str(cleanup), '--engine', engine, '--owner-label', label, '--run-id', inv['run_id'], '--cidfile', str(out / 'container.cid'), '--output', str(out / 'cleanup.json')])
cleaned = json.loads((out / 'cleanup.json').read_text()); assert cleaned['exit_status'] == 0
raw = run([engine, 'ps', '-a', '--format', '{{json .}}'])
save(out / 'independent-engine-query.json', {'returncode': 0, 'stdout': raw})
assert not any(inv['run_id'] in json.dumps(row) or cid.startswith(row['ID']) or row['ID'].startswith(cid) for row in [json.loads(line) for line in raw.splitlines() if line.strip()])
proof.update(stopped=state(), cleanup=cleaned, independent_engine_query_exit_status=0, owned_container_absent=True)
save(out / 'proof-stopped.json', proof)
print(json.dumps({'status': proof['status'], 'target_arch': args.arch, 'cleanup': 0, 'owned_absent': True}))
