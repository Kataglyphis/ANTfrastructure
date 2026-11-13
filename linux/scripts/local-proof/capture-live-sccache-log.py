#!/usr/bin/env python3
"""Hold the live RUN's existing error-log descriptor so its final bytes survive tmpfs teardown."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import time
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--pid", required=True, type=int)
parser.add_argument("--phase", required=True, choices=["gcc", "llvm", "rust", "python"])
parser.add_argument("--output", required=True, type=Path)
parser.add_argument("--timeout", type=int, default=10800)
args = parser.parse_args()
assert args.pid > 1 and 1 <= args.timeout <= 21600
process = Path(f"/proc/{args.pid}")


def start_ticks() -> str:
    return (process / "stat").read_text().rsplit(") ", 1)[1].split()[19]


ticks = start_ticks()
command = (process / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace").strip()
marker = {"gcc": "dockerfile-gcc", "llvm": "dockerfile-llvm", "rust": "/opt/scripts/toolchain/install-rust.sh", "python": "/opt/scripts/python/build_python.sh"}[args.phase]
assert marker in command, command
source = process / "root/tmp/sccache.log"
handle = source.open("rb")
initial = os.fstat(handle.fileno())
assert initial.st_size <= 64 * 1024 * 1024
args.output.mkdir(mode=0o700)
started = datetime.datetime.now(datetime.UTC).isoformat()
record = {"status": "capturing-live-existing-file", "pid": args.pid, "pid_start_ticks": ticks,
          "phase": args.phase, "command": command, "source": str(source), "device": initial.st_dev,
          "inode": initial.st_ino, "initial_size": initial.st_size, "started_at": started,
          "scope": __doc__, "producer_changed": False, "old_error_classification_claimed": False}
(args.output / "run.json").write_text(json.dumps(record, indent=2) + chr(10))
deadline = time.monotonic() + args.timeout
destination = args.output / "sccache-error.log"
with destination.open("xb") as output:
    destination.chmod(0o600)
    while True:
        chunk = handle.read()
        if chunk:
            assert output.tell() + len(chunk) <= 64 * 1024 * 1024
            output.write(chunk)
            output.flush()
        try:
            live = start_ticks() == ticks
        except FileNotFoundError:
            live = False
        if not live:
            output.write(handle.read())
            record["status"] = "captured-after-phase-process-exit"
            break
        if time.monotonic() >= deadline:
            record["status"] = "captured-partial-observation-timeout"
            break
        time.sleep(2)
final = os.fstat(handle.fileno())
handle.close()
raw = destination.read_bytes()
record.update(finished_at=datetime.datetime.now(datetime.UTC).isoformat(), size=len(raw),
              final_inode_size=final.st_size, sha256=hashlib.sha256(raw).hexdigest())
assert len(raw) == final.st_size
(args.output / "capture.json").write_text(json.dumps(record, indent=2) + chr(10))
print(json.dumps(record))
