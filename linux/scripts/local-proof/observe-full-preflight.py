#!/usr/bin/env python3
"""Read one confirmed full-preflight unit and its owned container's canonical partial status; never stop or restart."""

from __future__ import annotations

import argparse
import datetime
import json
import re
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--directory', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--processes', action='store_true')
args = parser.parse_args()
directory = args.directory.resolve()
assert not args.output.exists()
invocation = json.loads(directory.with_name(directory.name + '-invocation.json').read_text())
run_record = json.loads((directory / 'run.json').read_text())
assert invocation['revision'] == run_record['source_revision']
def query(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, capture_output=True, text=True, timeout=45, check=False)
unit = query(['systemctl', '--user', 'show', invocation['unit'], '--property=Id,LoadState,ActiveState,SubState,MainPID,Result,ExecMainStatus'])
assert unit.returncode == 0
state = dict(line.split('=', 1) for line in unit.stdout.splitlines() if '=' in line)
record = {'observed_at': datetime.datetime.now(datetime.UTC).isoformat(), 'unit': state,
          'source_revision': invocation['revision'], 'full_registry': invocation['full_registry'],
          'scope': __doc__, 'whole_registry_pass_claimed': False, 'run_status': run_record['status']}
if state['LoadState'] == 'loaded' and state['MainPID'] != '0':
    engine = str(Path.home() / '.local/bin/nerdctl')
    cid = (directory / 'container.cid').read_text().strip()
    assert re.fullmatch('[0-9a-f]{64}', cid)
    inspected = query([engine, 'inspect', cid])
    record['inspect_exit_status'] = inspected.returncode
    if inspected.returncode == 0:
        container = json.loads(inspected.stdout)[0]
        assert container['Id'] == cid and container['Config']['Labels']['org.kataglyphis.isolated-preflight'] == invocation['run_id']
        record.update(container_id=cid, actual_image=container['Image'], container_running=container['State']['Running'])
        if container['State']['Running']:
            result = query([engine, 'exec', cid, '/usr/bin/python3', '-B', '/tmp/isolated-preflight-source/linux/scripts/preflight-status.py'])
            record.update(status_query_exit_status=result.returncode, status_query_stderr=result.stderr)
            if result.returncode == 0:
                record['partial'] = json.loads(result.stdout)
            else:
                record['status_query_stdout'] = result.stdout
            if args.processes:
                record['configured_resources'] = {name: container['HostConfig'].get(name) for name in ['NanoCpus', 'Memory', 'CpuQuota', 'CpuPeriod']}
                commands = {
                    'processes': ['ps', '-eo', 'pid,ppid,stat,etimes,time,comm,args'],
                    'cpu_limit': ['cat', '/sys/fs/cgroup/cpu.max'],
                    'cpu_counters': ['cat', '/sys/fs/cgroup/cpu.stat'],
                    'memory_bytes': ['cat', '/sys/fs/cgroup/memory.current'],
                }
                record['resource_observations'] = {}
                for name, command in commands.items():
                    observed = query([engine, 'exec', cid, *command])
                    record['resource_observations'][name] = {'command': command, 'returncode': observed.returncode, 'stdout': observed.stdout, 'stderr': observed.stderr}
args.output.write_text(json.dumps(record, indent=2) + '\n')
if args.processes:
    print(json.dumps({key: record[key] for key in ['observed_at', 'unit', 'source_revision', 'partial', 'configured_resources'] if key in record}))
else:
    print(json.dumps(record))
