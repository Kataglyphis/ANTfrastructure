#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Run a repo's declared latency commands inside the CI image for quality-report.sh --perf-host.

Stdlib only, because it runs with python3 -I in the image; see docs/fleet-health.md#perf-host"""

from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
import time

SETUP_TIMEOUT = 7200
RUN_TIMEOUT = 600


def pin_cpus(count: int) -> list[int]:
    """Restrict this process tree to the first `count` CPUs it may use; returns the set."""
    allowed = sorted(os.sched_getaffinity(0))
    chosen = allowed[:max(1, count)]
    os.sched_setaffinity(0, chosen)
    return chosen


def last_json(stdout: str) -> object:
    """The JSON object on the last nonblank stdout line."""
    lines = [line for line in stdout.splitlines() if line.strip()]
    if not lines:
        raise ValueError("printed nothing on stdout")
    try:
        return json.loads(lines[-1])
    except json.JSONDecodeError as exc:
        raise ValueError(f"last stdout line is not JSON: {lines[-1][:120]!r}") from exc


def keys_of(command: dict[str, object]) -> list[str]:
    """The metric keys a command must print."""
    keys = command.get("keys")
    if not isinstance(keys, list) or not keys:
        raise ValueError(f"command {command.get('name')!r} declares no metric keys")
    return [str(key) for key in keys]


def one_run(command: dict[str, object], index: int) -> dict[str, float] | str:
    """One timed invocation: its values by key, or the reason it is not collected."""
    env = {**os.environ, "QUALITY_PERF_RUN": str(index)}
    done = subprocess.run(["bash", "-c", str(command["run"])], stdout=subprocess.PIPE, text=True,
                          env=env, timeout=RUN_TIMEOUT, check=False)
    if done.returncode != 0:
        raise ValueError(f"exited {done.returncode}")
    answer = last_json(done.stdout)
    if not isinstance(answer, dict):
        raise TypeError("last stdout line is not a JSON object")
    if "not_collected" in answer:
        return str(answer["not_collected"])
    values = {}
    for key in keys_of(command):
        value = answer.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)) \
                or not math.isfinite(value) or value <= 0:
            raise ValueError(f"key {key!r} is {value!r}, not a positive number")
        values[key] = float(value)
    return values


def measure(command: dict[str, object], runs: int) -> dict[str, object]:
    """Every run of one command; the first not-collected answer or failure ends it."""
    samples: dict[str, list[float]] = {key: [] for key in keys_of(command)}
    for index in range(runs):
        try:
            answer = one_run(command, index)
        except (TypeError, ValueError, subprocess.TimeoutExpired, OSError) as exc:
            return {"status": "failed", "reason": f"run {index + 1}: {exc}"}
        if isinstance(answer, str):
            return {"status": "not-collected", "reason": answer}
        for key, value in answer.items():
            samples[key].append(value)
    return {"status": "collected", "samples": samples}


def main(argv: list[str] | None = None) -> int:
    """Pin the CPUs, run the setup once, then every command `runs` times; write the samples."""
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--plan", required=True, help="the plan quality-report.sh wrote")
    ap.add_argument("--out", required=True, help="where the samples JSON goes")
    args = ap.parse_args(argv)
    with open(args.plan, encoding="utf-8") as fh:
        plan = json.load(fh)
    result: dict[str, object] = {"cpus": pin_cpus(int(plan["cpus"])), "commands": {}}
    started = time.monotonic()
    if plan.get("setup"):
        try:
            setup = subprocess.run(["bash", "-c", plan["setup"]], timeout=SETUP_TIMEOUT, check=False)
            result["setup_status"] = setup.returncode
        except subprocess.TimeoutExpired:
            result["setup_status"] = "timeout"
    result["setup_seconds"] = round(time.monotonic() - started, 1)
    if result.get("setup_status", 0) == 0:
        result["commands"] = {str(c["name"]): measure(c, int(plan["runs"])) for c in plan["commands"]}
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(result, fh, indent=2, sort_keys=True)
        fh.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
