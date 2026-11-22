#!/usr/bin/env python3
"""Retain explicit per-vertex cache records; absent diagnostic signatures do not prove error-free compiles."""

import argparse
import hashlib
import json
import re
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--log", type=Path, required=True)
parser.add_argument("--step", type=int, required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
assert args.step >= 0 and not args.output.exists()
raw = args.log.read_bytes()
prefix = re.compile(rf"^#{args.step}\s+\d+(?:\.\d+)?\s+(.*)$")
counter = re.compile(r"^sccache-stats\| (\d+) requests, (\d+) hits, (\d+) misses, (\d+) errors, (\d+) not cacheable$")
stats, drains, errors = [], [], []
for number, line in enumerate(raw.decode("utf-8", errors="replace").splitlines(), 1):
    match = prefix.match(re.sub(r"\x1b\[[0-9;]*m", "", line))
    if match is None:
        continue
    body = match[1]
    sample = {"line": number, "raw": line}
    totals = counter.fullmatch(body)
    if totals:
        stats.append({**sample, **dict(zip(("requests", "hits", "misses", "cache_errors", "not_cacheable"), map(int, totals.groups()), strict=True))})
    if body.startswith("sccache-drain|"):
        drains.append(sample)
    if re.match(r"^(?:sccache:|sccache-launcher[^\s]*:)", body):
        errors.append(sample)
assert len(stats) == 1, "Require exactly one vertex-final stats record"
record = {"log": str(args.log.resolve()), "log_sha256": hashlib.sha256(raw).hexdigest(), "step": args.step, "stats": stats,
          "drains": drains, "explicit_sccache_diagnostic_records": errors, "diagnostic_prefixes": ["sccache:", "sccache-launcher*:"], "scope": __doc__}
with args.output.open("x") as stream:
    json.dump(record, stream, indent=2)
    stream.write("\n")
print(json.dumps({"step": args.step, "stats": stats, "explicit_diagnostic_count": len(errors), "output": str(args.output)}))
