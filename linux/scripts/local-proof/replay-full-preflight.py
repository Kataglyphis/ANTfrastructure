#!/usr/bin/env python3
"""Reuse the full isolated source preflight profile at one new clean revision; no image or GPU acceptance."""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import subprocess
import uuid
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--template', required=True, type=Path)
parser.add_argument('--source', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--unit', required=True)
parser.add_argument('--jobs', type=int)
parser.add_argument('--memory')
parser.add_argument('--resource-admission', type=Path)
parser.add_argument('--existing-preflight', type=Path)
parser.add_argument('--compiler-unit')
args = parser.parse_args()
source = args.source.resolve()
out = args.output.resolve()
old = json.loads(args.template.read_text())
def checked(command: list[str]) -> str:
    return subprocess.run(command, capture_output=True, text=True, check=True, timeout=60).stdout
revision = checked(['git', '-C', str(source), 'rev-parse', 'HEAD']).strip()
assert not checked(['git', '-C', str(source), 'status', '--porcelain']).strip()
assert args.unit.startswith('webgpu-') and args.unit.endswith('.service')
assert checked(['systemctl', '--user', 'show', args.unit, '--property=LoadState', '--value']).strip() == 'not-found'
assert not out.exists()
assert not out.with_name(out.name + '-invocation.json').exists()
command = old['command']
assert command[:2] == ['systemd-run', '--user']
for required in ['--no-block', '--expand-environment=no', 'Type=oneshot', 'RemainAfterExit=yes', 'TimeoutStartSec=7200', 'TimeoutStopSec=300', '--native-tools-cache']:
    assert required in command
assert '--image' not in command
assert (source / 'linux/scripts/run-isolated-preflight.py').read_bytes() == (Path(old['source']) / 'linux/scripts/run-isolated-preflight.py').read_bytes()
assert (source / 'linux/scripts/preflight.sh').read_bytes() == (Path(old['source']) / 'linux/scripts/preflight.sh').read_bytes()
environment = dict(line.split('=', 1) for line in checked(['systemctl', '--user', 'show-environment']).splitlines() if '=' in line)
assert not {name: value for name, value in environment.items() if name in ['PREFLIGHT_ONLY', 'PREFLIGHT_SKIP', 'PREFLIGHT_MUTATION_SHARD']}
old_output = command[command.index('--output') + 1]
token = uuid.uuid4().hex
mapping = {old['source']: str(source), old_output: str(out), old['revision']: revision,
           old['run_id']: token, old['unit'].removesuffix('.service'): args.unit.removesuffix('.service')}
pattern = re.compile('|'.join(re.escape(key) for key in sorted(mapping, key=len, reverse=True)))
command = [pattern.sub(lambda match: mapping[match[0]], value) for value in command]
resource_proof = None
if args.jobs is not None or args.memory is not None:
    assert args.jobs == 8 and args.memory == '20g' and args.resource_admission is not None
    resource = json.loads(args.resource_admission.read_text())
    assert resource['candidate_jobs'] == args.jobs and resource['candidate_memory_bytes'] == 20 * 1024**3
    assert args.existing_preflight is not None and args.compiler_unit is not None
    existing_dir = args.existing_preflight.resolve(strict=True)
    existing_invocation = json.loads(existing_dir.with_name(existing_dir.name + '-invocation.json').read_text())
    existing_cid = (existing_dir / 'container.cid').read_text().strip()
    engine = str(Path.home() / '.local/bin/nerdctl')
    existing = json.loads(checked([engine,'inspect',existing_cid]))[0]
    assert existing['Config']['Labels']['org.kataglyphis.isolated-preflight'] == resource['existing_source_run_id'] == existing_invocation['run_id']
    assert existing_invocation['revision'] != revision and existing_invocation['unit'] != args.unit
    assert existing['State']['Running'], 'Reassess the standalone resource profile after the current source unit ends'
    current = int(checked([engine,'exec',existing_cid,'cat','/sys/fs/cgroup/memory.current']).strip())
    peak = int(checked([engine,'exec',existing_cid,'cat','/sys/fs/cgroup/memory.peak']).strip())
    maximum = int(checked([engine,'exec',existing_cid,'cat','/sys/fs/cgroup/memory.max']).strip())
    cpu = checked([engine,'exec',existing_cid,'cat','/sys/fs/cgroup/cpu.max']).split()
    assert cpu == ['400000','100000'] and maximum == 12 * 1024**3
    mem = {line.split(':',1)[0]:int(line.split()[1])*1024 for line in Path('/proc/meminfo').read_text().splitlines() if line.split()[1].isdigit()}
    available_cpus = len(os.sched_getaffinity(0))
    candidate_memory = resource['candidate_memory_bytes']
    assert candidate_memory >= 2 * peak, 'The 8-worker source profile needs headroom over twice the measured 4-worker peak'
    required_available = candidate_memory + max(0,maximum-current) + 8 * 1024**3
    assert mem['MemAvailable'] >= required_available, 'Leave memory for the existing source cap and8GiB host reserve'
    assert args.jobs + 4 <= available_cpus // 2, 'Leave at least half the host CPUs outside these two bounded source profiles'
    assert checked(['systemctl','--user','show',args.compiler_unit,'--property=LoadState','--value']).strip() == 'not-found'
    command[command.index('--jobs')+1] = str(args.jobs)
    command[command.index('--memory')+1] = args.memory
    resource_proof = {'observed_at':datetime.datetime.now(datetime.UTC).isoformat(),'existing_source_unit':existing_invocation['unit'],
                      'existing_source_revision':existing_invocation['revision'],'existing_source_run_id':existing_invocation['run_id'],
                      'existing_memory_current':current,'existing_memory_peak':peak,'existing_memory_cap':maximum,
                      'new_source_jobs':args.jobs,'new_source_memory_cap':candidate_memory,'host_memory_available':mem['MemAvailable'],
                      'required_host_available':required_available,'host_available_cpus':available_cpus,'other_producer_changed':False,
                      'all_default_gates_preserved':True,'new_source_only':True}
temporary = Path.home() / '.cache' / args.unit.removesuffix('.service')
assert not temporary.exists() and all(not (p / '.git').exists() for p in [temporary, *temporary.parents])
temporary.mkdir(mode=0o700)
command[command.index('/usr/bin/python3'):command.index('/usr/bin/python3')] = ['-E', f'TMPDIR={temporary}', '-p', 'KillMode=control-group']
registry = len(json.loads((source / 'docs/scripts/mutations.json').read_text()))
record = {'created_at': datetime.datetime.now(datetime.UTC).isoformat(), 'unit': args.unit, 'source': str(source), 'revision': revision,
          'run_id': token, 'full_registry': registry, 'command': command, 'template': str(args.template.resolve()),
          'scope': __doc__, 'outlives_turn': True, 'publication': False}
record['resource_admission'] = resource_proof
invocation = out.with_name(out.name + '-invocation.json')
invocation.write_text(json.dumps(record, indent=2) + '\n')
result = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
record.update(launch_status=result.returncode, stdout=result.stdout, stderr=result.stderr)
invocation.write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps({'unit': args.unit, 'launch_status': result.returncode, 'revision': revision, 'full_registry': registry}))
raise SystemExit(result.returncode)
