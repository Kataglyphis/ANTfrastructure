#!/usr/bin/env python3
"""Keep host command boundaries, diagnostics and interrupted-child cleanup consistent."""

import subprocess
import sys
from pathlib import Path


def checked_output(argv: list[str], source: str | None = None, timeout: float = 20) -> str:
    result = subprocess.run(argv, input=source, text=True, capture_output=True,
                            timeout=timeout, check=False)
    if result.returncode:
        raise RuntimeError(f"{argv[0]} exited {result.returncode}: {result.stderr.strip()[:1200]}")
    return result.stdout


def run_logged(argv: list[str], output: Path) -> int:
    with output.open("wb") as log, subprocess.Popen(
        argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    ) as process:
        try:
            assert process.stdout is not None
            for line in process.stdout:
                log.write(line)
                log.flush()
                sys.stdout.buffer.write(line)
                sys.stdout.buffer.flush()
            return process.wait()
        except BaseException:
            try:
                process.terminate()
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            raise
