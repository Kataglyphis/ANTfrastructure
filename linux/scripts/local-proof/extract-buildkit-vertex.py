#!/usr/bin/env python3
"""Preserve an exact completed RUN vertex; incomplete output cannot serve as phase evidence."""

import argparse
import hashlib
import json
import re
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--log", required=True, type=Path)
parser.add_argument("--step", required=True, type=int)
parser.add_argument("--output", required=True, type=Path)
parser.add_argument("--verify-existing", action="store_true")
args = parser.parse_args()
assert args.step >= 0
raw = args.log.read_bytes()
start = re.search(rb"(?m)^#" + str(args.step).encode() + rb" \[[^\]\r\n]+\] RUN ", raw)
assert start is not None, "RUN header is missing"
end = re.search(rb"(?m)^#" + str(args.step).encode() + rb" (?:DONE [0-9.]+s|CACHED)\r?\n", raw[start.start():])
assert end is not None, "RUN is not complete"
stop = start.start() + end.end()
data = raw[start.start():stop]
metadata = {"source_log": str(args.log.resolve()), "source_observed_bytes": len(raw), "step": args.step,
            "start_byte": start.start(), "end_byte": stop, "sha256": hashlib.sha256(data).hexdigest(),
            "scope": __doc__}
if args.verify_existing:
    assert args.output.read_bytes() == data
else:
    metadata_path = args.output.with_suffix(".extraction.json")
    assert not args.output.exists() and not metadata_path.exists()
    with args.output.open("xb") as output:
        output.write(data)
    metadata_path.write_text(json.dumps(metadata, indent=2) + chr(10))
print(json.dumps(metadata))
