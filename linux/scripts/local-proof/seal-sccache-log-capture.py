#!/usr/bin/env python3
"""Seal one bounded log reader's actual file and terminal state; no cache-error classification or build acceptance."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import re
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--invocation", type=Path, required=True)
args = parser.parse_args()
inv = json.loads(args.invocation.read_text())
command = inv["command"]
out = Path(command[command.index("--output") + 1])
assert re.fullmatch(r"webgpu-compiler[0-9]+-(?:gcc|llvm|rust|python)-error-capture-[0-9-]+\.service", inv["unit"]) is not None and "error-capture" in inv["unit"]


def state() -> dict[str, str]:
    result = subprocess.run(["systemctl", "--user", "show", inv["unit"], "--property=Id,LoadState,ActiveState,SubState,MainPID,Result,ExecMainStatus,ExecMainExitTimestampMonotonic"],
                            capture_output=True, text=True, timeout=30, check=True)
    return dict(line.split("=", 1) for line in result.stdout.splitlines())


terminal = state()
assert terminal["LoadState"] == "loaded" and terminal["ActiveState"] == "active" and terminal["SubState"] == "exited"
assert terminal["MainPID"] == terminal["ExecMainStatus"] == "0" and terminal["Result"] == "success"
assert int(terminal["ExecMainExitTimestampMonotonic"]) > 0
capture = json.loads((out / "capture.json").read_text())
assert capture["phase"] == command[command.index("--phase") + 1] and capture["pid"] == int(command[command.index("--pid") + 1])
assert capture["status"] in ("captured-after-phase-process-exit", "captured-partial-observation-timeout")
log = out / "sccache-error.log"
assert not log.is_symlink() and log.stat().st_size == capture["size"] == capture["final_inode_size"]
with log.open("rb") as stream:
    assert hashlib.file_digest(stream, "sha256").hexdigest() == capture["sha256"]
if "capture_script_sha256" in inv:
    script = Path(command[command.index("--pid") - 1])
    assert hashlib.sha256(script.read_bytes()).hexdigest() == inv["capture_script_sha256"]
proof = {"status": "passed-actual-error-log-file-retention-only", "observed_at": datetime.datetime.now(datetime.UTC).isoformat(),
         "terminal_before_stop": terminal, "capture": capture,
         "complete_phase_process_observed": capture["status"] == "captured-after-phase-process-exit",
         "scope": __doc__, "compiler_or_image_pass_claimed": False}
path = out / "unit-proof.json"
assert not path.exists()
path.write_text(json.dumps(proof, indent=2) + chr(10))
subprocess.run(["systemctl", "--user", "stop", inv["unit"]], check=True, timeout=30)
proof["stopped"] = state()
assert proof["stopped"]["ActiveState"] == "inactive" and proof["stopped"]["MainPID"] == "0"
(out / "unit-proof-stopped.json").write_text(json.dumps(proof, indent=2) + chr(10))
print(json.dumps({"unit": inv["unit"], "log_bytes": capture["size"], "complete_phase_process_observed": proof["complete_phase_process_observed"], "unit_stopped": True}))
