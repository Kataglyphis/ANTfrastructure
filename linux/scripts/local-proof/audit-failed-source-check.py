#!/usr/bin/env python3
"""Retain direct assertion, completed mutation or quality failures; incomplete mutator failures and source acceptance are not covered."""

from __future__ import annotations

import argparse
import collections
import datetime
import hashlib
import json
import re
import runpy
import subprocess
import sys
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
sys.path.insert(0, str(source / 'linux/scripts'))


def failure_accounting() -> tuple[int, list[str], list[str], list[str]]:
    mutation_log = out / 'mutations.log'
    if not mutation_log.exists():
        reports = [path.name for path in sorted(out.glob('*-tests.log')) if re.search(
            r'\d+/\d+ assertion\(s\) FAILED|^FAILED\b', path.read_text(), re.MULTILINE)]
        assert reports, 'Missing direct suite failure evidence'
        assert not (out / 'preflight.log').exists(), 'Direct failure cannot contain a preflight report'
        return 0, [], ['direct source suites'], reports
    mutation_text = re.sub(r'\x1b\[[0-9;]*m', '', mutation_log.read_text())
    survived = re.findall(r'^\[\d+/\d+\]\s+FAIL:\s+(\S+)\s+SURVIVED\b', mutation_text, re.MULTILINE)
    if survived:
        passed = re.findall(r'^\[\d+/\d+\]\s+bites\s+(\S+)\s', mutation_text, re.MULTILINE)
        expected = [row['id'] for row in json.loads((out / 'selected-mutations.json').read_text())]
        assert len(expected) == len(set(expected)) and collections.Counter(passed + survived) == collections.Counter(expected)
        summary = re.search(r'^FAILED: (\d+) of (\d+) entr', mutation_text, re.MULTILINE)
        assert summary and (int(summary[1]), int(summary[2])) == (len(survived), len(expected))
        assert 'OK: every recorded mutation is caught' not in mutation_text
        return len(passed), survived, ['mutation gate (can the tests fail?)'], []
    counter = runpy.run_path(str(source / 'linux/scripts/seal-mutation-unit.py'))['mutation_ids']
    count = counter(out / 'selected-mutations.json', mutation_log, False)
    text = re.sub(r'\x1b\[[0-9;]*m', '', (out / 'preflight.log').read_text())
    failed_groups = re.findall(r'^✗ (.+)$', text, re.MULTILINE)
    assert failed_groups and 'All preflight checks passed.' not in text
    return count, [], failed_groups, []


count, survived, failed_groups, direct_reports = failure_accounting()
inputs = ['invocation.json', 'cleanup.json', 'selected-mutations.json', *direct_reports]
if (out / 'mutations.log').exists():
    inputs.append('mutations.log')
if (out / 'preflight.log').exists():
    inputs.append('preflight.log')
proof = {'status': 'failed-targeted-source-check-preserved', 'observed_at': datetime.datetime.now(datetime.UTC).isoformat(),
         'unit': inv['unit'], 'terminal_before_stop': before, 'raw_status': int(before['ExecMainStatus']),
         'actual_mutations_passed': count, 'actual_mutations_survived': survived, 'failed_preflight_groups': failed_groups,
         'direct_failed_logs': direct_reports, 'mutation_execution_started': (out / 'mutations.log').exists(),
         'cleanup_exit_status': 0, 'independent_engine_query_exit_status': 0, 'owned_container_absent': True,
         'source_accepted': False, 'scope': __doc__,
         'inputs_sha256': {name: hashlib.sha256((out / name).read_bytes()).hexdigest() for name in inputs}}
(out / 'failure-proof.json').write_text(json.dumps(proof, indent=2) + '\n')
subprocess.run(['systemctl', '--user', 'stop', inv['unit']], check=True)
after = unit_state()
assert after['MainPID'] == '0' and after['ActiveState'] in ('inactive', 'failed')
proof['stopped'] = after
(out / 'failure-proof-stopped.json').write_text(json.dumps(proof, indent=2) + '\n')
print(json.dumps({key: proof[key] for key in ['status', 'raw_status', 'actual_mutations_passed', 'failed_preflight_groups', 'owned_container_absent']}))
