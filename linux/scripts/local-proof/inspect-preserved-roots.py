#!/usr/bin/env python3
"""Read expected local Git heads and cleanliness without repairing or publishing any checkout."""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime
import hashlib
import json
import re
import subprocess
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from proof_types import Json

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--reference', required=True, type=Path)
parser.add_argument('--additions', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
assert not args.output.exists()
expected = json.loads(args.reference.read_text())['roots'] + json.loads(args.additions.read_text())
assert len({row['path'] for row in expected}) == len(expected)
def inspect(row: Json) -> Json:
    path = Path(row['path'])
    revision = row['expected_head']
    assert path.is_absolute() and re.fullmatch('[0-9a-f]{40}', revision)
    head = subprocess.run(['git', '--no-optional-locks', '-C', str(path), 'rev-parse', 'HEAD'], capture_output=True, text=True, check=True, timeout=45).stdout.strip()
    status = subprocess.run(['git', '--no-optional-locks', '-C', str(path), 'status', '--porcelain'], capture_output=True, text=True, check=True, timeout=45).stdout
    return {'path': str(path), 'head': head, 'expected_head': revision, 'clean': not status.strip(), 'status': status}
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    rows = list(pool.map(inspect, expected))
passed = all(row['head'] == row['expected_head'] and row['clean'] for row in rows)
record = {'observed_at': datetime.datetime.now(datetime.UTC).isoformat(), 'all_expected_clean': passed, 'roots': rows,
          'preserved_accepted_E30': any(row['head'] == row['expected_head'] == 'e30b3e904eeb4f033b939a59086850c1f7dc8652' and row['clean'] for row in rows),
          'publication': False, 'scope': __doc__,
          'input_sha256': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in [args.reference, args.additions]}}
args.output.write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps({'all_expected_clean': passed, 'roots': len(rows), 'preserved_accepted_E30': record['preserved_accepted_E30']}))
raise SystemExit(0 if passed and record['preserved_accepted_E30'] else 1)
