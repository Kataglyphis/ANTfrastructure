#!/usr/bin/env python3
"""Exercise the real probe CLI on the preserved insufficient compiler; an expected refusal is not new-image, SDK or GPU acceptance."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import shlex
import shutil
import subprocess
import uuid
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('action',choices=['launch','worker','seal'])
parser.add_argument('--directory',type=Path,required=True)
parser.add_argument('--unit',required=True)
parser.add_argument('--source',type=Path)
parser.add_argument('--parent-plan',type=Path)
parser.add_argument('--parent-proof',type=Path)
args = parser.parse_args()
out = args.directory.resolve()

def save(name: str, value: object) -> None:
    (out / name).write_text(json.dumps(value,indent=2)+'\n')

if args.action == 'worker':
    command = ['python3','-B','/cross-probe.py','--evidence',str(out),'--mode','default','--gcc-pin','16.2.0','--llvm-pin','23.1.5']
    result = subprocess.run(command, capture_output=True, text=True, timeout=300, check=False)
    (out / 'probe.stdout').write_text(result.stdout)
    (out / 'probe.stderr').write_text(result.stderr)
    assert result.returncode == 1
    assert 'AssertionError: Native LLVM must carry exactly all three configured backends' in result.stderr
    assert not (out / 'cross-clang.json').exists()
    raw = json.loads((out / 'cross-clang-raw.json').read_text())
    assert raw['schema_version'] == 1 and raw['backends']['returncode'] == 0 and raw['backends']['stdout'].split() == ['X86']
    assert len(raw['wrappers']) == 6 and set(raw['native_programs']) == {'c','cxx'}
    save('refusal-result.json',{'status':'passed-real-old-compiler-cross-backend-refusal-only','command':command,
                              'probe_returncode':result.returncode,'observed_native_backends':['X86'],
                              'success_receipt_absent':True,'raw_collection_completed':True,'scope':__doc__})
    print('Actual old compiler refused for its missing native cross backends; no image accepted.')
    raise SystemExit(0)

assert args.source and args.parent_plan and args.parent_proof
source = args.source.resolve()
tools = Path(__file__).resolve().parent
engine = str(Path.home() / '.local/bin/nerdctl')
label = 'org.kataglyphis.cross-clang-refusal-control'
plan = json.loads(args.parent_plan.read_text())
parent = json.loads(args.parent_proof.read_text())
assert args.unit.startswith('webgpu-cross-clang-refusal-control-') and args.unit.endswith('.service')

def run(command: list[str]) -> str:
    return subprocess.check_output(command,text=True,timeout=60)

def sha(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()

def state() -> dict[str, str]:
    raw = run(['systemctl','--user','show',args.unit,'--property=Id,LoadState,ActiveState,SubState,MainPID,Result,ExecMainStatus'])
    return dict(line.split('=',1) for line in raw.splitlines() if '=' in line)

cleanup = source / 'linux/scripts/cleanup-owned-containers.py'
if args.action == 'launch':
    assert parent['status'] == 'passed-qualified-native-compiler-OCI-and-base-ancestry' and parent['source_revision'] == plan['source_revision']
    assert not out.exists() and state()['LoadState'] == 'not-found'
    image = json.loads(run([engine,'image','inspect',plan['local_image']]))[0]
    assert image['Id'] == parent['config'] and any(value.endswith('@'+parent['manifest']) for value in image['RepoDigests'])
    assert not image['Config'].get('Entrypoint')
    run(['python3',str(cleanup),'--help'])
    out.mkdir()
    (out / 'results').mkdir()
    (out / 'inputs').mkdir()
    shutil.copyfile(tools / 'probe-cross-clang-image.py',out / 'cross-probe.py')
    shutil.copyfile(Path(__file__),out / 'control.py')
    for name in ['native-wrapper-probe.c','native-wrapper-probe.cc']:
        shutil.copyfile(tools / name,out / 'inputs' / name)
    token = uuid.uuid4().hex
    stop = ['python3',str(cleanup),'--engine',engine,'--owner-label',label,'--run-id',token,'--cidfile',str(out / 'container.cid'),
            '--output',str(out / 'retained-stop-cleanup.json'),'--retain']
    temporary = Path.home() / '.cache' / args.unit.removesuffix('.service')
    assert not temporary.exists() and all(not (path / '.git').exists() for path in [temporary,*temporary.parents])
    temporary.mkdir(mode=0o700)
    command = ['systemd-run','--user','--no-block','--expand-environment=no','--unit='+args.unit]
    for setting in ['Type=oneshot','RemainAfterExit=yes','TimeoutStartSec=600','TimeoutStopSec=120','KillMode=control-group',
                    f'StandardOutput=append:{out}/stdout.log',f'StandardError=append:{out}/stderr.log','ExecStopPost='+shlex.join(stop)]:
        command += ['-p',setting]
    for setting in ['LC_ALL=C',f'HOME={Path.home()}',f'TMPDIR={temporary}',f'PATH={Path.home()}/.local/bin:/usr/local/bin:/usr/bin:/bin']:
        command += ['-E',setting]
    command += [engine,'run','--name','ant-'+args.unit.removesuffix('.service'),'--cidfile',str(out / 'container.cid'),'--label',label+'='+token,
                '--pull','never','--init','--security-opt','apparmor=unconfined','--network','none','--cpus','2','--memory','2g','--user','0:0','--env','LC_ALL=C',
                '-v',f'{out}/results:/evidence','-v',f'{out}/inputs:/inputs:ro','-v',f'{out}/cross-probe.py:/cross-probe.py:ro',
                '-v',f'{out}/control.py:/control.py:ro',plan['local_image'],'python3','/control.py','worker','--directory','/evidence','--unit',args.unit]
    record = {'unit':args.unit,'owner_label':label,'run_id':token,'command':command,'expected_manifest':parent['manifest'],
              'expected_config':parent['config'],'image_environment':image['Config']['Env'],'scope':__doc__,'publication':False,
              'input_sha256':{name:sha(out / name) for name in ['cross-probe.py','control.py','inputs/native-wrapper-probe.c','inputs/native-wrapper-probe.cc']}}
    save('invocation.json',record)
    print(run(command).strip())
    raise SystemExit(0)

inv = json.loads((out / 'invocation.json').read_text())
assert inv['unit'] == args.unit and inv['owner_label'] == label
before = state()
assert before['LoadState'] == 'loaded' and before['ActiveState'] == 'active' and before['SubState'] == 'exited'
assert before['MainPID'] == before['ExecMainStatus'] == '0' and before['Result'] == 'success'
cid = (out / 'container.cid').read_text().strip()
container = json.loads(run([engine,'inspect',cid]))[0]
assert container['Id'] == cid and container['Image'] == inv['expected_manifest'] and container['Config']['Labels'][label] == inv['run_id']
assert not container['State']['Running'] and container['State']['ExitCode'] == 0 and not container['HostConfig'].get('Privileged',False)
assert all(sha(out / name) == digest for name,digest in inv['input_sha256'].items())
result = json.loads((out / 'results/refusal-result.json').read_text())
raw = json.loads((out / 'results/cross-clang-raw.json').read_text())
baked = dict(value.split('=',1) for value in inv['image_environment'])
assert all(value == baked.get(name) for name,value in raw['environment'].items())
assert result['probe_returncode'] == 1 and result['success_receipt_absent'] and result['raw_collection_completed']
assert not (out / 'results/cross-clang.json').exists()
proof = {**result,'observed_at':datetime.datetime.now(datetime.UTC).isoformat(),'terminal_before_stop':before,
         'actual_image_manifest':container['Image'],'ordinary_image_environment_preserved':True,
         'results_sha256':{path.name:sha(path) for path in (out / 'results').iterdir() if path.is_file()}}
assert not (out / 'proof.json').exists()
save('proof.json',proof)
run(['systemctl','--user','stop',args.unit])
assert state()['MainPID'] == '0' and state()['ActiveState'] == 'inactive'
retained = json.loads((out / 'retained-stop-cleanup.json').read_text())
assert retained['exit_status'] == 0 and retained['retain']
run(['python3',str(cleanup),'--engine',engine,'--owner-label',label,'--run-id',inv['run_id'],
     '--cidfile',str(out / 'container.cid'),'--output',str(out / 'cleanup.json')])
cleaned = json.loads((out / 'cleanup.json').read_text())
assert cleaned['exit_status'] == 0
rows = run([engine,'ps','-a','--format','{{json .}}'])
save('independent-engine-query.json',{'returncode':0,'stdout':rows})
assert not any(inv['run_id'] in json.dumps(row) or cid.startswith(row['ID']) or row['ID'].startswith(cid) for row in [json.loads(line) for line in rows.splitlines() if line.strip()])
proof.update(stopped=state(),cleanup_exit_status=0,independent_engine_query_exit_status=0,owned_container_absent=True)
save('proof-stopped.json',proof)
print(json.dumps({'status':proof['status'],'actual_probe_returncode':1,'owned_container_absent':True}))
