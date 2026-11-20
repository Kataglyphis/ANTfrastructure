#!/usr/bin/env python3
"""Assemble targeted source evidence after strict mutation sealing; no full preflight, SDK or GPU proof."""

import argparse
import collections
import datetime
import hashlib
import json
import re
import subprocess
from pathlib import Path

from proof_profiles import TARGETED_STATUSES

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--directory', type=Path, required=True)
parser.add_argument('--owner', type=Path, required=True)
parser.add_argument('--proof-kind', choices=list(TARGETED_STATUSES), default='sdk-llvm-prefix')
args = parser.parse_args()
out = args.directory.resolve()
assert not (out / 'source-proof.json').exists()
inv = json.loads((out / 'invocation.json').read_text())
source = Path(inv['source'])
patch = subprocess.check_output(['git', '-C', str(args.owner), 'diff', '--cached', '--full-index', '--binary'])
assert hashlib.sha256(patch).hexdigest() == inv['patch_sha256']
profile = (source / 'linux/scripts/03-media/build/migraphx/source-check.sh').read_text()
slugs = re.findall(r'^PREFLIGHT_ONLY=([a-z0-9,-]+)', profile, re.MULTILINE)
assert len(slugs) == 1
slugs = slugs[0].split(',')
mapping = dict(re.findall(r'run_check\s+(\S+)\s+"([^"]+)"', (source / 'linux/scripts/preflight.sh').read_text()))
assert not (set(slugs) - mapping.keys())
expected = [mapping[slug] for slug in slugs]
text = re.sub(r'\x1b\[[0-9;]*m', '', (out / 'preflight.log').read_text())
actual = collections.Counter(re.findall(r'^✓ (.+)$', text, re.MULTILINE))
assert 'All preflight checks passed.' in text and not re.search(r'^✗ ', text, re.MULTILINE)
assert len(expected) == len(set(expected)) and all(actual[name] == 1 for name in expected)
seal = json.loads((out / 'mutation-proof-stopped.json').read_text())
assert seal['status'] == 'passed-mutation-unit-only' and seal['unit'] == inv['unit']
assert seal['stopped']['MainPID'] == '0' and seal['stopped']['ActiveState'] == 'inactive'
assert seal['unique_actual_mutations'] == inv['selected_mutations']
cleanup = json.loads((out / 'cleanup.json').read_text())
assert cleanup['exit_status'] == 0 and cleanup['run_id'] == inv['run_id']
query = subprocess.run([str(Path.home() / '.local/bin/nerdctl'), 'ps', '-a', '--format', '{{json .}}'], capture_output=True, text=True, timeout=60, check=True)
cid = (out / 'container.cid').read_text().strip()
rows = [json.loads(line) for line in query.stdout.splitlines() if line.strip()]
assert not any(inv['run_id'] in json.dumps(row) or cid.startswith(row['ID']) or row['ID'].startswith(cid) for row in rows)
(out / 'source-proof-engine-query.json').write_text(json.dumps({'returncode': query.returncode, 'stdout': query.stdout, 'stderr': query.stderr}, indent=2) + '\n')
kind_status = TARGETED_STATUSES
proof = {'status': kind_status[args.proof_kind], 'proof_kind': args.proof_kind, 'observed_at': datetime.datetime.now(datetime.UTC).isoformat(),
         'parent_source_revision': inv['head'], 'source_snapshot': str(source), 'owner_source': str(args.owner.resolve()),
         'patch_sha256': inv['patch_sha256'], 'exact_current_staged_patch_match': True,
         'actual_affected_mutations': inv['selected_mutations'], 'quality_groups': expected, 'quality_group_count': len(expected),
         'cleanup_exit_status': 0, 'independent_engine_query_exit_status': 0, 'owned_container_absent': True,
         'full_preflight_claimed': False, 'SDK_acceptance_claimed': False, 'scope': __doc__,
         'inputs_sha256': {name: hashlib.sha256((out / name).read_bytes()).hexdigest()
                          for name in ['invocation.json', 'mutation-proof-stopped.json', 'cleanup.json', 'preflight.log']}}
(out / 'source-proof.json').write_text(json.dumps(proof, indent=2) + '\n')
print(json.dumps({'status': proof['status'], 'mutations': proof['actual_affected_mutations'], 'quality_groups': len(expected), 'exact_patch_match': True, 'owned_absent': True}))
