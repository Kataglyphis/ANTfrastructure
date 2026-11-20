#!/usr/bin/env python3
"""Seal a validated local commit with the canonical hook-mutation sealer; no publication or full preflight."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import re
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--directory', required=True, type=Path)
args = parser.parse_args()
out = args.directory.resolve()
inv = json.loads((out / 'invocation.json').read_text())
source = Path(inv['source'])
assert not (out / 'commit-proof.json').exists()
def git(*arguments: str) -> bytes:
    return subprocess.check_output(['git', '-C', str(source), *arguments], timeout=60)
head = git('rev-parse', 'HEAD').decode().strip()
assert git('rev-parse', 'HEAD^').decode().strip() == inv['parent']
assert hashlib.sha256(git('diff', '--full-index', '--binary', 'HEAD^', 'HEAD')).hexdigest() == inv['patch_sha256']
assert not git('status', '--porcelain').strip()
text = (out / 'commit.log').read_text()
assert 'pre-commit: OK' in text
ids = re.findall(r'^\[\d+/\d+\]\s+bites\s+(\S+)\s', text, re.MULTILINE)
assert len(ids) == len(set(ids)) == inv['expected_hook_sample']
registry = json.loads((source / 'docs/scripts/mutations.json').read_text())
by_id = {row['id']: row for row in registry}
assert len(by_id) == len(registry) and set(ids) <= by_id.keys()
selected = [row for row in registry if row['id'] in set(ids)]
assert all(row['target'] in inv['files'] for row in selected)
manifest = out / 'selected-hook-mutations.json'
assert not manifest.exists()
manifest.write_text(json.dumps(selected, indent=1) + '\n')
subprocess.run(['python3', str(source / 'linux/scripts/seal-mutation-unit.py'), '--unit', inv['unit'], '--manifest', str(manifest),
                '--log', str(out / 'commit.log'), '--output', str(out / 'mutation-proof.json'), '--selected'], check=True, timeout=60)
seal = json.loads((out / 'mutation-proof-stopped.json').read_text())
assert seal['unique_actual_mutations'] == len(ids)
proof = {'status': 'passed-local-source-commit-normal-hooks-only', 'observed_at': datetime.datetime.now(datetime.UTC).isoformat(),
         'head': head, 'parent': inv['parent'], 'patch_sha256': inv['patch_sha256'], 'exact_committed_patch_match': True,
         'source_proof': inv['source_proof'], 'actual_hook_mutations': len(ids), 'normal_hook_status': 0,
         'strict_mutation_seal': str(out / 'mutation-proof-stopped.json'), 'clean': True, 'full_preflight_claimed': False,
         'source': str(source), 'publication': False, 'scope': __doc__}
(out / 'commit-proof.json').write_text(json.dumps(proof, indent=2) + '\n')
print(json.dumps({'head': head, 'normal_hook_status': 0, 'actual_hook_mutations': len(ids), 'exact_patch_match': True}))
