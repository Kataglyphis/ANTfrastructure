#!/usr/bin/env python3
"""Run only the owner's canonical regular-layer cleanup, preserving independent before/after identities and the normal disk floor."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('action', choices=['launch', 'worker', 'seal'])
parser.add_argument('--directory', type=Path, required=True)
parser.add_argument('--unit', required=True)
parser.add_argument('--keep-gb', type=int, default=120)
parser.add_argument('--idle-store', action='store_true')
parser.add_argument('--authorization', type=Path, required=True)
args = parser.parse_args()
assert re.fullmatch(r'webgpu-safe-prune-[A-Za-z0-9_.-]+\.service', args.unit)
assert args.keep_gb > 0 and (args.keep_gb >= 100 or args.idle_store)
out = args.directory.resolve()
tool_dir = Path(__file__).resolve().parent
root = tool_dir.parents[1]
canonical = root / 'linux/host-config/prune-safe.sh'
disk_helper = root / 'linux/scripts/01-core/disk-guard.sh'
authorization = args.authorization.resolve(strict=True)
assert 'agents may run the existing `linux/host-config/prune-safe.sh` autonomously' in authorization.read_text()

def run(command: list[str], timeout: int = 60) -> str:
    return subprocess.run(command, check=True, text=True, capture_output=True, timeout=timeout).stdout

def state() -> dict[str, str]:
    raw = run(['systemctl', '--user', 'show', args.unit, '--property=Id,LoadState,ActiveState,SubState,MainPID,Result,ExecMainStatus'])
    return dict(line.split('=', 1) for line in raw.splitlines() if '=' in line)

def save(name: str, value: object) -> None:
    (out / name).write_text(json.dumps(value, indent=2) + '\n')

if args.action == 'launch':
    assert state()['LoadState'] == 'not-found' and not out.exists()
    temporary = Path.home() / '.cache' / args.unit.removesuffix('.service')
    assert not temporary.exists() and all(not (p / '.git').exists() for p in [temporary, *temporary.parents])
    out.mkdir()
    temporary.mkdir(mode=0o700)
    command = ['systemd-run', '--user', '--no-block', '--expand-environment=no', '--unit=' + args.unit]
    for value in ['Type=oneshot', 'RemainAfterExit=yes', 'TimeoutStartSec=600', 'TimeoutStopSec=60', 'KillMode=control-group',
                  f'StandardOutput=append:{out}/unit.log', f'StandardError=append:{out}/unit.log']:
        command += ['-p', value]
    for value in ['LC_ALL=C', f'HOME={Path.home()}', f'TMPDIR={temporary}', f'PATH={Path.home()}/.local/bin:/usr/local/bin:/usr/bin:/bin']:
        command += ['-E', value]
    command += ['python3', str(Path(__file__).resolve()), 'worker', '--directory', str(out), '--unit', args.unit, '--keep-gb', str(args.keep_gb), '--authorization', str(authorization)]
    if args.idle_store:
        command += ['--idle-store']
    save('invocation.json', {'created_at': datetime.datetime.now(datetime.UTC).isoformat(), 'command': command,
                            'canonical_script_sha256': hashlib.sha256(canonical.read_bytes()).hexdigest(),
                            'keep_gb': args.keep_gb, 'idle_store_required': args.idle_store, 'duplicate_cachemount_cleanup': False, 'scope': __doc__})
    print(run(command).strip())
elif args.action == 'worker':
    invocation = json.loads((out / 'invocation.json').read_text())
    assert invocation['keep_gb'] == args.keep_gb and invocation['idle_store_required'] == args.idle_store
    assert hashlib.sha256(canonical.read_bytes()).hexdigest() == invocation['canonical_script_sha256']
    snapshot = tool_dir / 'nerdctl-full-state.py'
    print(run(['python3', str(snapshot), str(out / 'before')], timeout=180), flush=True)
    before = json.loads((out / 'before/snapshot.json').read_text())
    canonical_free = run(['bash', '-euo', 'pipefail', '-c', 'source "$1"; _disk_guard_free_gb "$2"',
                          'autonomous-prune-admission', str(disk_helper), str(root)]).strip()
    assert canonical_free.isdigit()
    if before['disk_free_bytes'] >= 193273528320 and int(canonical_free) >= 180:
        save('skip-proof.json', {'status': 'skipped-reserve-already-sufficient', 'free_bytes': before['disk_free_bytes'], 'canonical_free_gib': int(canonical_free), 'reclaim_performed': False})
    else:
        if args.idle_store:
            assert not before['running_containers'] and all(value['in_use'] == 0 for value in before['buildkit_record_types'].values())
        environment = dict(os.environ, PRUNE_KEEP_GB=str(args.keep_gb), PRUNE_DUP_CACHEMOUNTS='0', DRY_RUN='0')
        with (out / 'prune.log').open('x') as log:
            result = subprocess.run(['bash', str(canonical)], env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=300, check=False)
        (out / 'prune.exit-status').write_text(str(result.returncode) + '\n')
        print(run(['python3', str(snapshot), str(out / 'after')], timeout=180), flush=True)
        verify = ['python3', str(tool_dir / 'verify-safe-prune.py'), '--directory', str(out), '--keep-gb', str(args.keep_gb), '--disk-helper', str(disk_helper)]
        if args.idle_store:
            verify += ['--idle-store']
        print(run(verify), flush=True)
else:
    assert not (out / 'unit-proof-stopped.json').exists()
    before = state()
    assert before['LoadState'] == 'loaded' and before['ActiveState'] == 'active' and before['SubState'] == 'exited'
    assert before['MainPID'] == before['ExecMainStatus'] == '0' and before['Result'] == 'success'
    receipt = json.loads((out / ('proof.json' if (out / 'proof.json').exists() else 'skip-proof.json')).read_text())
    run(['systemctl', '--user', 'stop', args.unit])
    after = state()
    assert after['MainPID'] == '0' and after['ActiveState'] == 'inactive'
    save('unit-proof-stopped.json', {'status': 'completed-safe-prune-controller', 'terminal_before_stop': before, 'stopped': after, 'cleanup_result': receipt['status'], 'scope': __doc__})
    print(json.dumps({'unit': args.unit, 'status': receipt['status'], 'stopped': True}))
