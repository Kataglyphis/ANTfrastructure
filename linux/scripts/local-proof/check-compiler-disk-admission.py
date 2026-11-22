#!/usr/bin/env python3
"""Record the plan's canonical disk admission without reclaiming or changing its floor."""

import argparse
import datetime
import json
import runpy
import shutil
import subprocess
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--plan", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
assert not args.output.exists()
plan = json.loads(args.plan.read_text())
source = Path(plan["source"])
head = subprocess.run(["git", "-C", str(source), "rev-parse", "HEAD"], capture_output=True, text=True, check=True, timeout=30).stdout.strip()
assert head == plan["source_revision"]
path = Path(plan["output"]).parent
sys.path.insert(0, str(source / "linux/scripts"))
probe = source / "linux/scripts/launch-migraphx-configure-proof.py"
record = {"observed_at": datetime.datetime.now(datetime.UTC).isoformat(), "source_revision": head,
          "path": str(path), "available_bytes": shutil.disk_usage(path).free,
          "required_bytes": plan["required_bytes"], "reclaim_performed": False}
try:
    record.update(runpy.run_path(str(probe))["require_build_disk"](path))
    record["accepted"] = True
except ValueError as error:
    record.update(accepted=False, reason=str(error))
with args.output.open("x") as stream:
    json.dump(record, stream, indent=2)
    stream.write(chr(10))
print(json.dumps(record))
