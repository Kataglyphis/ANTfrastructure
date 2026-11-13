#!/usr/bin/env python3
"""Preserve one exact mutation-job byte slice; the unchanged sealer verifies IDs and terminal state separately."""

import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--receipt', type=Path, required=True)
args = parser.parse_args()
assert not args.output.exists() and not args.receipt.exists(), 'Preserve prior evidence'
raw = args.source.read_bytes()
start_marker = b'=== mutation gate: can these tests fail? ===\n'
end_marker = b'OK: every recorded mutation is caught by its tests\n'
assert raw.count(start_marker) == 1, 'Expected one actual whole-manifest mutation job'
start = raw.index(start_marker)
end = raw.index(end_marker, start) + len(end_marker)
chunk = raw[start:end]
assert raw.count(end_marker) == 1 and b'FAIL:' not in chunk
assert b'All preflight checks passed.' in raw[end:], 'Missing enclosing preflight success'
record = {'source': str(args.source.resolve()), 'source_sha256': hashlib.sha256(raw).hexdigest(),
          'start_byte': start, 'end_byte_exclusive': end,
          'mutation_job_sha256': hashlib.sha256(chunk).hexdigest(), 'scope': __doc__}
args.output.write_bytes(chunk)
args.receipt.write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps(record))
