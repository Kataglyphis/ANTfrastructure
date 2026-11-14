#!/usr/bin/env python3
"""Reuse a bounded read-only log-capture profile for an actual selected outer RUN; no build acceptance."""

import argparse
import datetime
import hashlib
import json
import subprocess
from pathlib import Path

from cache_capture_profile import PHASE_MARKERS, validate_capture_unit

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--template", type=Path, required=True)
parser.add_argument("--phase", choices=tuple(PHASE_MARKERS), required=True)
parser.add_argument("--pid", type=int, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--unit", required=True)
parser.add_argument("--producer-unit", required=True)
args = parser.parse_args()
previous = json.loads(args.template.read_text())
previous["producer_unit"] = args.producer_unit
command = previous["command"].copy()
assert command[:3] == ["systemd-run", "--user", "--no-block"]
assert args.pid > 1
validate_capture_unit(args.unit, args.phase)
for expected in ("Type=oneshot", "RemainAfterExit=yes", "TimeoutStartSec=10860", "TimeoutStopSec=60", "KillMode=control-group", "MemoryMax=256M"):
    assert expected in command
old_output = command[command.index("--output") + 1]
old_phase = command[command.index("--phase") + 1]
out = args.output.resolve()
assert not out.exists()
query = subprocess.run(["systemctl", "--user", "show", args.unit, "--property=LoadState", "--value"], capture_output=True, text=True, check=True, timeout=30)
assert query.stdout.strip() == "not-found"
producer = subprocess.run(["systemctl", "--user", "show", previous["producer_unit"], "--property=ActiveState,MainPID"], capture_output=True, text=True, check=True, timeout=30)
facts = dict(line.split("=", 1) for line in producer.stdout.splitlines())
assert facts["ActiveState"] in ("active", "activating") and int(facts["MainPID"]) > 0
command = [value.replace(previous["unit"], args.unit).replace(old_output, str(out)).replace(f"{old_phase}-error-capture-unit.log", f"{args.phase}-error-capture-unit.log") for value in command]
command[command.index("--pid") + 1] = str(args.pid)
command[command.index("--phase") + 1] = args.phase
script = Path(__file__).with_name("capture-live-sccache-log.py")
command[command.index("--pid") - 1] = str(script)
for index, value in enumerate(command):
    if value.startswith(("StandardOutput=append:", "StandardError=append:")):
        command[index] = value.split("=", 1)[0] + "=append:" + str(out.parent / f"{args.phase}-error-capture-unit.log")
assert script.name == "capture-live-sccache-log.py" and script.is_file()
record = {"created_at": datetime.datetime.now(datetime.UTC).isoformat(), "unit": args.unit,
          "producer_unit": previous["producer_unit"], "command": command, "reused_profile": str(args.template.resolve()),
          "capture_script_sha256": hashlib.sha256(script.read_bytes()).hexdigest(), "producer_changed": False,
          "capture_inputs_sha256": {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                                   for path in [script, script.with_name("cache_capture_profile.py")]},
          "scope": __doc__}
invocation = out.parent / f"{args.phase}-error-capture-invocation.json"
assert not invocation.exists()
invocation.write_text(json.dumps(record, indent=2) + chr(10))
result = subprocess.run(command, capture_output=True, text=True, timeout=30, check=False)
record.update(launch_status=result.returncode, stdout=result.stdout, stderr=result.stderr)
invocation.write_text(json.dumps(record, indent=2) + chr(10))
print(json.dumps({"unit": args.unit, "launch_status": result.returncode, "stderr": result.stderr}))
raise SystemExit(result.returncode)
