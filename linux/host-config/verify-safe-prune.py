#!/usr/bin/env python3
"""Seal canonical cleanup snapshots and the current unchanged disk guard; no deletion is performed."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import subprocess
from pathlib import Path
from typing import TypedDict

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--directory', required=True, type=Path)
parser.add_argument('--keep-gb', required=True, type=int)
parser.add_argument('--disk-helper', required=True, type=Path)
parser.add_argument('--idle-store', action='store_true')
args = parser.parse_args()
out = args.directory.resolve()
assert not (out / 'proof.json').exists()
before, after = [json.loads((out / name / 'snapshot.json').read_text()) for name in ('before', 'after')]
assert args.keep_gb > 0
if args.keep_gb < 100:
    assert args.idle_store, 'Budgets below100GB require an explicitly idle store'
if args.idle_store:
    assert not before['running_containers'] and not after['running_containers']
    assert all(value['in_use'] == 0 for snapshot in [before, after] for value in snapshot['buildkit_record_types'].values())
assert (out / 'prune.exit-status').read_text().strip() == '0'
assert before['cachemount_ids'] == after['cachemount_ids']
keys = ('Repository', 'Tag', 'Digest', 'ID', 'Platform')
class ImageSnapshot(TypedDict):
    image_records: list[dict[str, str]]


def image_identities(snapshot: ImageSnapshot) -> list[tuple[str, ...]]:
    return sorted(tuple(row[key] for key in keys) for row in snapshot['image_records'])
assert image_identities(before) == image_identities(after)
query = subprocess.run(['bash', '-euo', 'pipefail', '-c', 'source "$1"; _disk_guard_free_gb "$2"',
                        'verify-safe-prune', str(args.disk_helper.resolve()), str(Path.home())],
                       capture_output=True, text=True, timeout=20, check=True)
assert query.stdout.strip().isdigit()
required = 193273528320
canonical = int(query.stdout.strip())
proof = {
    'status': 'passed-authorized-canonical-layer-cleanup',
    'observed_at': datetime.datetime.now(datetime.UTC).isoformat(),
    'keep_layer_gb': args.keep_gb,
    'basis': 'Standing owner authorization for canonical regular-layer cleanup; duplicate cleanup disabled.',
    'cachemount_ids_preserved': len(after['cachemount_ids']),
    'image_identities_preserved': len(after['image_records']),
    'free_bytes_before': before['disk_free_bytes'],
    'free_bytes_after': after['disk_free_bytes'],
    'required_bytes': required,
    'canonical_free_gib_now': canonical,
    'reserve_satisfied': after['disk_free_bytes'] >= required and canonical >= 180,
    'duplicate_cachemount_cleanup': False,
    'idle_store_verified': args.idle_store,
    'mid_build_lower_budget_used': False,
    'source_receipts_or_images_deleted': False,
    'scope': __doc__,
    'input_sha256': {str(path.relative_to(out)): hashlib.sha256(path.read_bytes()).hexdigest()
                     for path in [out / 'before/snapshot.json', out / 'after/snapshot.json', out / 'prune.log', out / 'prune.exit-status']},
}
(out / 'proof.json').write_text(json.dumps(proof, indent=2) + '\n')
print(json.dumps(proof))
