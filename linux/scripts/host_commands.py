#!/usr/bin/env python3
"""Keep host command boundaries, diagnostics and interrupted-child cleanup consistent."""

import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


def strip_ansi(text: str) -> str:
    return re.sub(r"\x1b\[[0-9;]*m", "", text)


def engine_json_lines(engine: str, output: Path, filters: list[str] | None = None) -> list[dict[str, Any]]:
    command = [engine, "ps", "-a", "--no-trunc", "--format", "{{json .}}"]
    for value in filters or []:
        command += ["--filter", value]
    result = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
    with output.open("x", encoding="utf-8") as stream:
        json.dump({"command": command, "returncode": result.returncode, "stdout": result.stdout,
                   "stderr": result.stderr}, stream, indent=2)
        stream.write("\n")
    if result.returncode or result.stderr:
        raise ValueError("Independent engine query failed")
    rows = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    if not all(re.fullmatch(r"[0-9a-f]{64}", row["ID"]) for row in rows):
        raise ValueError("Engine query truncated container IDs")
    return rows


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
