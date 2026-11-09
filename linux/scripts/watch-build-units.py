#!/usr/bin/env python3
"""Observe existing user units and logs without starting, stopping or accepting a build."""

import argparse
import datetime
import json
import subprocess
import sys
import time
from collections.abc import Mapping
from pathlib import Path
from typing import NotRequired, TypedDict

from host_commands import checked_output

FIELDS = "Id,LoadState,ActiveState,SubState,MainPID,Result,ExecMainStatus,ExecMainExitTimestampMonotonic"


class Snapshot(TypedDict):
    observed_at: str
    units: list[dict[str, str]]
    chain_status: dict[str, object]
    logs: list[dict[str, object]]
    preflight: NotRequired[dict[str, object]]


def parse_units(text: str) -> list[dict[str, str]]:
    units = []
    for block in text.strip().split("\n\n"):
        fields = dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
        if fields.get("LoadState") != "loaded" or not fields.get("Id"):
            raise ValueError(f"unit is missing or not loaded: {fields}")
        for key in ("MainPID", "ExecMainStatus", "ExecMainExitTimestampMonotonic"):
            int(fields.get(key) or "0")
        units.append(fields)
    return units


def terminal(unit: dict[str, str]) -> bool:
    ended = int(unit.get("ExecMainExitTimestampMonotonic") or "0") > 0
    failed = unit.get("Result") not in (None, "", "success")
    return unit.get("ActiveState") in ("inactive", "failed") and (ended or failed)


def log_tail(path: Path) -> dict[str, object]:
    with path.open("rb") as stream:
        stream.seek(max(0, path.stat().st_size - 8000))
        lines = stream.read().decode(errors="replace").splitlines()
    return {"path": str(path), "lines": [line[:600] for line in lines[-4:]]}


def preflight_status(engine: str, container: str) -> dict[str, object]:
    probe = Path(__file__).with_name("preflight-status.py").read_text()
    result = json.loads(checked_output([engine, "exec", "-i", container, "python3", "-B", "-"], probe))
    if not isinstance(result, dict):
        raise TypeError("preflight status probe returned no object")
    return result


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--unit", action="append", required=True)
    parser.add_argument("--engine", default="nerdctl")
    parser.add_argument("--preflight-container")
    parser.add_argument("--chain-status", action="append", type=Path, default=[])
    parser.add_argument("--log", action="append", type=Path, default=[])
    parser.add_argument("--interval", type=float, default=45)
    parser.add_argument("--timeout", type=float, default=5400)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.interval <= 0 or args.timeout <= 0:
        parser.error("interval and timeout must be positive")
    if any(unit.startswith("-") or any(c.isspace() for c in unit) for unit in args.unit):
        parser.error("unit names cannot contain whitespace or start with an option")
    return args


def snapshot(args: argparse.Namespace) -> Snapshot:
    units = parse_units(checked_output(["systemctl", "--user", "show", f"--property={FIELDS}", *args.unit]))
    result: Snapshot = {"observed_at": datetime.datetime.now(datetime.UTC).isoformat(), "units": units,
              "chain_status": {str(path): json.loads(path.read_text()) for path in args.chain_status},
              "logs": [log_tail(path) for path in args.log]}
    if args.preflight_container and not any(terminal(unit) for unit in units):
        result["preflight"] = preflight_status(args.engine, args.preflight_container)
    return result


def emit(data: Mapping[str, object], output: Path | None) -> None:
    line = json.dumps(data)
    print(line, flush=True)
    if output is not None:
        output.parent.mkdir(parents=True, exist_ok=True)
        with output.open("a") as stream:
            stream.write(line + "\n")


def main() -> int:
    args = arguments()
    deadline = time.monotonic() + args.timeout
    while True:
        state = snapshot(args)
        emit(state, args.output)
        units = state["units"]
        if any(terminal(unit) for unit in units):
            return int(any(unit.get("Result") not in (None, "", "success") or int(unit.get("ExecMainStatus") or "0") for unit in units))
        preflight = state.get("preflight", {})
        mutation = preflight.get("mutation")
        if isinstance(mutation, dict) and mutation.get("failures"):
            return 1
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            emit({"status": "observation-timeout", "producer_changed": False}, args.output)
            return 124
        time.sleep(min(args.interval, remaining))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, TypeError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"watch-build-units: {error}", file=sys.stderr)
        sys.exit(2)
