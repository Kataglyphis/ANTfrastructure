#!/usr/bin/env python3
"""Commit an exact validated staged source patch with unchanged normal hooks; no publication."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import subprocess
from pathlib import Path

from proof_commands import command_bytes
from proof_commands import command_text as run
from proof_profiles import TARGETED_STATUSES

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', required=True, type=Path)
parser.add_argument('--source-proof', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--unit', required=True)
parser.add_argument('--message', required=True)
args = parser.parse_args()
source = args.source.resolve()
out = args.output.resolve()
proof = json.loads(args.source_proof.read_text())
assert proof['status'] in TARGETED_STATUSES.values()
assert proof['owner_source'] == str(source) and proof['exact_current_staged_patch_match']
assert proof['cleanup_exit_status'] == proof['independent_engine_query_exit_status'] == 0 and proof['owned_container_absent']
patch = command_bytes(['git', '-C', str(source), 'diff', '--cached', '--full-index', '--binary'])
assert patch and hashlib.sha256(patch).hexdigest() == proof['patch_sha256']
assert not run(['git', '-C', str(source), 'diff', '--name-only']).strip()
assert run(['systemctl', '--user', 'show', args.unit, '--property=LoadState', '--value']).strip() == 'not-found'
assert args.unit.startswith('webgpu-') and args.unit.endswith('.service') and not out.exists()
temporary = Path.home() / '.cache' / args.unit.removesuffix('.service')
assert not temporary.exists() and all(not (p / '.git').exists() for p in [temporary, *temporary.parents])
temporary.mkdir(mode=0o700)
out.mkdir()
paths = set(run(['git', '-C', str(source), 'diff', '--cached', '--name-only']).splitlines())
registry = json.loads((source / 'docs/scripts/mutations.json').read_text())
selected = [entry for entry in registry if entry['target'] in paths]
assert selected
command = ['systemd-run', '--user', '--no-block', '--expand-environment=no', f'--unit={args.unit}']
for value in ['Type=oneshot', 'RemainAfterExit=yes', 'TimeoutStartSec=1200', 'TimeoutStopSec=300', 'KillMode=control-group',
              f'WorkingDirectory={source}', f'StandardOutput=append:{out}/commit.log', f'StandardError=append:{out}/commit.log']:
    command += ['-p', value]
for value in ['LC_ALL=C', f'HOME={Path.home()}', f'TMPDIR={temporary}', f'PATH={Path.home()}/.local/bin:{Path.home()}/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin']:
    command += ['-E', value]
command += ['git', '-c', 'user.name=Codex', '-c', 'user.email=codex@local', '-c', 'core.hooksPath=linux/host-config/git-hooks', 'commit', '-m', args.message]
record = {'created_at': datetime.datetime.now(datetime.UTC).isoformat(), 'source': str(source), 'unit': args.unit,
          'parent': run(['git', '-C', str(source), 'rev-parse', 'HEAD']).strip(), 'patch_sha256': proof['patch_sha256'],
          'files': sorted(paths), 'matched_staged_mutations': len(selected), 'expected_hook_sample': min(16, len(selected)),
          'source_proof': str(args.source_proof.resolve()), 'command': command, 'publication': False}
(out / 'invocation.json').write_text(json.dumps(record, indent=2) + '\n')
result = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
record.update(launch_status=result.returncode, stdout=result.stdout, stderr=result.stderr)
(out / 'invocation.json').write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps({'unit': args.unit, 'launch_status': result.returncode, 'matched_staged_mutations': len(selected)}))
raise SystemExit(result.returncode)
