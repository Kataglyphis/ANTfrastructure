#!/usr/bin/env python3
"""Reuse a preserved bounded loader replay; this is not new-image or SDK acceptance."""

import argparse
import datetime
import hashlib
import json
import re
import shutil
import subprocess
import uuid
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--template", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--unit", required=True)
parser.add_argument("--container", required=True)
args = parser.parse_args()
old = args.template.resolve().parent
out = args.output.resolve()
previous = json.loads(args.template.read_text())
assert re.fullmatch(r"webgpu-native-llvm-loader-replay-[A-Za-z0-9_.-]+\.service", args.unit)
assert re.fullmatch(r"ant-webgpu-native-llvm-loader-replay-[A-Za-z0-9_.-]+", args.container)
assert previous["owner_label"] == "org.kataglyphis.native-llvm-loader-replay"
command = previous["command"]
assert command[:2] == ["systemd-run", "--user"]
for value in ("--no-block", "--expand-environment=no", "Type=oneshot", "RemainAfterExit=yes", "TimeoutStartSec=600", "TimeoutStopSec=120", "KillMode=control-group"):
    assert value in command, value
for flag, value in (("--network", "none"), ("--pull", "never"), ("--cpus", "2"), ("--memory", "2g"), ("--security-opt", "apparmor=unconfined")):
    assert command.count(flag) == 1 and command[command.index(flag) + 1] == value
assert "--entrypoint" not in command and "--privileged" not in command
state = subprocess.run(["systemctl", "--user", "show", "--property=LoadState", "--value", args.unit], capture_output=True, text=True, check=True, timeout=20)
assert state.stdout.strip() == "not-found" and not out.exists()
out.mkdir()
(out / "results").mkdir()
owner = Path(previous["source_owner"])
for filename in ("probe-compiler-defaults.py", "llvm-loader-path.sh"):
    shutil.copyfile(owner / "linux/scripts/06-packaging" / filename, out / filename)
for filename in ("plain-load.py", "replay.sh"):
    shutil.copyfile(old / filename, out / filename)
token = uuid.uuid4().hex
mapping = {str(old): str(out), previous["unit"].removesuffix(".service"): args.unit.removesuffix(".service"), previous["container"]: args.container, previous["run_id"]: token}
pattern = re.compile("|".join(re.escape(key) for key in sorted(mapping, key=len, reverse=True)))
command = [pattern.sub(lambda match: mapping[match[0]], value) for value in command]
record = {**previous, "created_at": datetime.datetime.now(datetime.UTC).isoformat(), "unit": args.unit, "container": args.container, "run_id": token, "command": command,
          "input_sha256": {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in out.iterdir() if path.is_file()}, "reused_profile": str(args.template.resolve()), "profile_driver": str(Path(__file__).resolve())}
for key in ("launch_status", "stdout", "stderr"):
    record.pop(key, None)
(out / "invocation.json").write_text(json.dumps(record, indent=2) + "\n")
result = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
record.update(launch_status=result.returncode, stdout=result.stdout, stderr=result.stderr)
(out / "invocation.json").write_text(json.dumps(record, indent=2) + "\n")
print(json.dumps({"unit": args.unit, "launch_status": result.returncode, "stderr": result.stderr}))
raise SystemExit(result.returncode)
