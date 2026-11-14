#!/usr/bin/env python3
"""Retain an existing reviewed compiler/GPU/Media RUN log through teardown; no error classification, provenance authentication or build acceptance."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import stat
import time
from pathlib import Path
from typing import TYPE_CHECKING

from cache_capture_profile import PHASE_MARKERS

if TYPE_CHECKING:
    from typing import BinaryIO

    from proof_types import Json

MAX_LOG = 64 * 1024 * 1024


def start_ticks(process: Path) -> str:
    return (process / 'stat').read_text().rsplit(') ', 1)[1].split()[19]


def copy_pending(handle: BinaryIO, output: BinaryIO) -> None:
    chunk = handle.read(MAX_LOG + 1)
    assert output.tell() + len(chunk) <= MAX_LOG, 'Cache log exceeds the reader bound'
    output.write(chunk)
    output.flush()


def stream_log(handle: BinaryIO, process: Path, ticks: str, destination: Path, timeout: int) -> str:
    deadline = time.monotonic() + timeout
    identity = os.fstat(handle.fileno())
    with destination.open('xb') as output:
        destination.chmod(0o600)
        while True:
            copy_pending(handle, output)
            try:
                live = start_ticks(process) == ticks
            except FileNotFoundError:
                live = False
            if not live:
                copy_pending(handle, output)
                return 'captured-after-phase-process-exit'
            current = (process / 'root/tmp/sccache.log').stat()
            assert (current.st_dev, current.st_ino) == (identity.st_dev, identity.st_ino), 'Live cache log inode changed'
            if time.monotonic() >= deadline:
                return 'captured-partial-observation-timeout'
            time.sleep(2)


def capture_log(pid: int, phase: str, output: Path, timeout: int, process: Path | None = None) -> Json:
    assert pid > 1 and 1 <= timeout <= 21600, 'Cache reader PID or lifetime is invalid'
    process = process if process is not None else Path(f'/proc/{pid}')
    ticks = start_ticks(process)
    command = (process / 'cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace').strip()
    assert PHASE_MARKERS[phase] in command, 'Cache reader process does not match its phase'
    source = process / 'root/tmp/sccache.log'
    assert stat.S_ISREG(source.lstat().st_mode), 'Existing cache log must be a regular file'
    with source.open('rb') as handle:
        initial = os.fstat(handle.fileno())
        assert initial.st_size <= MAX_LOG, 'Existing cache log exceeds the reader bound'
        output.mkdir(mode=0o700)
        record: Json = {'status':'capturing-live-existing-file', 'pid':pid, 'pid_start_ticks':ticks,
                  'phase':phase, 'command':command, 'source':str(source), 'device':initial.st_dev,
                  'inode':initial.st_ino, 'initial_size':initial.st_size, 'started_at':datetime.datetime.now(datetime.UTC).isoformat(),
                  'scope':__doc__, 'producer_changed':False, 'old_error_classification_claimed':False}
        (output / 'run.json').write_text(json.dumps(record, indent=2) + '\n')
        destination = output / 'sccache-error.log'
        status = stream_log(handle, process, ticks, destination, timeout)
        final = os.fstat(handle.fileno())
    raw = destination.read_bytes()
    record.update(status=status, finished_at=datetime.datetime.now(datetime.UTC).isoformat(), size=len(raw),
                  final_inode_size=final.st_size, sha256=hashlib.sha256(raw).hexdigest())
    assert len(raw) == final.st_size, 'Cache reader did not retain every file byte'
    (output / 'capture.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', required=True, type=int)
    parser.add_argument('--phase', required=True, choices=tuple(PHASE_MARKERS))
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--timeout', type=int, default=10800)
    args = parser.parse_args()
    print(json.dumps(capture_log(args.pid, args.phase, args.output, args.timeout)))


if __name__ == '__main__':
    main()
