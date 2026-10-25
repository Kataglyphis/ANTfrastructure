#!/usr/bin/env python3
"""Query parsed local workflow fixtures without running their jobs."""
import importlib
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
V = importlib.import_module("verify_workflow_conventions")

path = pathlib.Path(sys.argv[1])
lane = V.load_yaml(path)
jobs = V.value(lane, "jobs") or {}
call = V.value(V.value(lane, "on"), "workflow_call")
inputs = V.value(call, "inputs") or {}
secrets = V.value(call, "secrets") or {}
plan = V.value(jobs, "plan")
job = V.value(jobs, sys.argv[3])
build = V.value(jobs, sys.argv[2])
steps = V.value(job, "steps") if job else []
raw = path.read_text(encoding="utf-8")


def run_text() -> str:
    return "\n".join(str(V.value(step, "run") or "") for step in (steps or []))


def run_blocks(name: str) -> str:
    # The loader leaves block scalars opaque, so assertions read the original indentation.
    lines = raw.splitlines()
    start = lines.index(f"  {name}:")
    end = next((i for i in range(start + 1, len(lines))
                if re.match(r"^  [A-Za-z0-9_-]+:\s*$", lines[i])), len(lines))
    out, i = [], start
    while i < end:
        match = re.match(r"^(\s*)run: \|", lines[i])
        i += 1
        while match and i < end and (not lines[i].strip() or
                                     len(lines[i]) - len(lines[i].lstrip()) > len(match.group(1))):
            out.append(lines[i])
            i += 1
    return "\n".join(out)


print(eval(sys.argv[4]))
