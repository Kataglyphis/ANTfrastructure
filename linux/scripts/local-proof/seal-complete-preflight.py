#!/usr/bin/env python3
"""Seal a completed full source run through unchanged extraction, strict mutation and evidence tools; no image/GPU proof."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--directory', required=True, type=Path)
parser.add_argument('--reference', required=True, type=Path)
args = parser.parse_args()
out = args.directory.resolve()
tool_dir = Path(__file__).resolve().parent

def checked(command: list[str]) -> str:
    return subprocess.run(command, capture_output=True, text=True, check=True, timeout=60).stdout

def main() -> None:
    inv = json.loads(out.with_name(out.name + '-invocation.json').read_text())
    record = json.loads((out / 'run.json').read_text())
    raw = checked(['systemctl', '--user', 'show', inv['unit'], '--property=Id,LoadState,ActiveState,SubState,MainPID,Result,ExecMainStatus,ExecMainExitTimestampMonotonic'])
    state = dict(line.split('=', 1) for line in raw.splitlines())
    if not (state['LoadState'] == 'loaded' and state['ActiveState'] == 'active' and state['SubState'] == 'exited'
            and state['MainPID'] == state['ExecMainStatus'] == '0' and state['Result'] == 'success'
            and int(state['ExecMainExitTimestampMonotonic']) > 0):
        raise ValueError('Full preflight is still running or not successful; no seal, extraction or stop was attempted')
    assert record['status'] == 'passed' and record['command_exit_status'] == record['cleanup_exit_status'] == 0
    assert record['source_revision'] == inv['revision'] and record['owner_run_id'] == inv['run_id']
    source = Path(record['source_snapshot'])
    assert checked(['git', '-C', str(source), 'rev-parse', 'HEAD']).strip() == inv['revision']
    assert not checked(['git', '-C', str(source), 'status', '--porcelain']).strip()
    reference = json.loads(args.reference.read_text())
    assert reference['status'] == 'passed-complete-Linux-source-preflight-only'
    assert (source / 'linux/scripts/preflight.sh').read_bytes() == (Path(reference['source_snapshot']) / 'linux/scripts/preflight.sh').read_bytes()
    assert len(json.loads((source / 'docs/scripts/mutations.json').read_text())) == inv['full_registry']
    names = ['mutations-only.log', 'mutator-extraction.json', 'mutation-proof.json', 'mutation-proof-stopped.json', 'complete-preflight-proof.json', 'seal-orchestration.json']
    assert not any((out / name).exists() for name in names), 'Preserve previous artifacts and inspect a partial sealing attempt'
    commands = [
        ['python3', str(tool_dir / 'extract-preflight-mutator.py'), '--source', str(out / 'preflight.log'),
         '--output', str(out / 'mutations-only.log'), '--receipt', str(out / 'mutator-extraction.json')],
        ['python3', str(source / 'linux/scripts/seal-mutation-unit.py'), '--unit', inv['unit'],
         '--manifest', str(source / 'docs/scripts/mutations.json'), '--log', str(out / 'mutations-only.log'), '--output', str(out / 'mutation-proof.json')],
        ['python3', str(tool_dir / 'complete-preflight-receipt.py'), '--directory', str(out), '--reference', str(args.reference.resolve())],
    ]
    outputs = []
    for command in commands:
        outputs.append({'command': command, 'stdout': checked(command)})
    proof = json.loads((out / 'complete-preflight-proof.json').read_text())
    assert proof['source_revision'] == inv['revision'] and proof['actual_full_registry_mutations'] == inv['full_registry']
    assert proof['unit_stopped_after_seal'] and proof['owned_container_absent']
    summary = {'status': 'passed-existing-full-preflight-sealing-tools', 'terminal_before_any_sealing': state,
               'commands': outputs, 'complete_proof_sha256': hashlib.sha256((out / 'complete-preflight-proof.json').read_bytes()).hexdigest(),
               'scope': __doc__}
    (out / 'seal-orchestration.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps({'status': summary['status'], 'revision': inv['revision'], 'mutations': inv['full_registry'], 'groups': proof['actual_preflight_group_count']}))

try:
    main()
except (OSError, ValueError, AssertionError, KeyError, subprocess.SubprocessError) as error:
    print(f'Full preflight sealing refused: {error}', file=sys.stderr)
    raise SystemExit(2)
