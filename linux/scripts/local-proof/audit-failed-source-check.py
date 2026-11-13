#!/usr/bin/env python3
"""Preserve one actually failed source check and its cleanup; this cannot create a successful source seal."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import re
import runpy
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--directory', type=Path, required=True)
args = parser.parse_args()
out = args.directory.resolve(strict=True)
assert not (out / 'failure-proof.json').exists()
inv = json.loads((out / 'invocation.json').read_text())
source = Path(inv['source'])
assert inv['owner_label'] == 'org.kataglyphis.migraphx-source'
assert re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*\.service', inv['unit'])
fields = 'Id,LoadState,ActiveState,SubState,MainPID,Result,ExecMainStatus,ExecMainExitTimestampMonotonic'

def unit_state() -> dict[str, str]:
    raw = subprocess.check_output(['systemctl', '--user', 'show', inv['unit'], '--property=' + fields], text=True)
    return dict(line.split('=', 1) for line in raw.splitlines() if '=' in line)

before = unit_state()
assert before['Id'] == inv['unit'] and before['LoadState'] == 'loaded'
assert before['ActiveState'] == before['SubState'] == 'failed' and before['MainPID'] == '0'
assert int(before['ExecMainStatus']) > 0 and int(before['ExecMainExitTimestampMonotonic']) > 0
cleanup = json.loads((out / 'cleanup.json').read_text())
assert cleanup['exit_status'] == 0 and cleanup['run_id'] == inv['run_id']
cid = (out / 'container.cid').read_text().strip()
assert re.fullmatch(r'[a-f0-9]{64}', cid)
query = subprocess.run([str(Path.home() / '.local/bin/nerdctl'), 'ps', '-a', '--format', '{{json .}}'], capture_output=True, text=True, timeout=60, check=True)
rows = [json.loads(line) for line in query.stdout.splitlines() if line.strip()]
assert not any(inv['run_id'] in json.dumps(row) or cid.startswith(row['ID']) or row['ID'].startswith(cid) for row in rows)
(out / 'failure-engine-query.json').write_text(json.dumps({'returncode': query.returncode, 'stdout': query.stdout, 'stderr': query.stderr}, indent=2) + '\n')
import sys

sys.path.insert(0, str(source / 'linux/scripts'))
counter = runpy.run_path(str(source / 'linux/scripts/seal-mutation-unit.py'))['mutation_ids']
count = counter(out / 'selected-mutations.json', out / 'mutations.log', False)
text = re.sub(r'\x1b\[[0-9;]*m', '', (out / 'preflight.log').read_text())
failed_groups = re.findall(r'^✗ (.+)$', text, re.MULTILINE)
assert failed_groups and 'All preflight checks passed.' not in text
proof = {'status': 'failed-targeted-source-check-preserved', 'observed_at': datetime.datetime.now(datetime.UTC).isoformat(),
         'unit': inv['unit'], 'terminal_before_stop': before, 'raw_status': int(before['ExecMainStatus']),
         'actual_mutations_passed': count, 'failed_preflight_groups': failed_groups,
         'cleanup_exit_status': 0, 'independent_engine_query_exit_status': 0, 'owned_container_absent': True,
         'source_accepted': False, 'scope': __doc__,
         'inputs_sha256': {name: hashlib.sha256((out / name).read_bytes()).hexdigest() for name in ['invocation.json', 'cleanup.json', 'preflight.log', 'mutations.log']}}
(out / 'failure-proof.json').write_text(json.dumps(proof, indent=2) + '\n')
subprocess.run(['systemctl', '--user', 'stop', inv['unit']], check=True)
after = unit_state()
assert after['MainPID'] == '0' and after['ActiveState'] in ('inactive', 'failed')
proof['stopped'] = after
(out / 'failure-proof-stopped.json').write_text(json.dumps(proof, indent=2) + '\n')
print(json.dumps({key: proof[key] for key in ['status', 'raw_status', 'actual_mutations_passed', 'failed_preflight_groups', 'owned_container_absent']}))
