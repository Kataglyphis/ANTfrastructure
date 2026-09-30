#!/usr/bin/env python3
"""Runs a Python app bundle's self-test command and proves its JSON report; see docs/python-app-bundles.md § What the builders do."""

import argparse
import json
import subprocess
import sys


def last_report(text: str) -> dict:
    """The last block from a bare '{' line to a bare '}' line: ONNX Runtime may print notices with braces first."""
    lines = text.splitlines()
    ends = [i for i, line in enumerate(lines) if line == "}"]
    starts = [i for i in range(ends[-1] + 1) if lines[i] == "{"] if ends else []
    if not starts:
        raise ValueError("the self-test printed no JSON report")
    return json.loads("\n".join(lines[starts[-1] : ends[-1] + 1]))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default="", help="the report's onnxruntime_module must lie under this directory")
    parser.add_argument("command", nargs=argparse.REMAINDER, help="the launcher and its self-test arguments")
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("no self-test command")
    run = subprocess.run(command, stdout=subprocess.PIPE, text=True, check=False)
    sys.stderr.write(run.stdout)
    if run.returncode != 0:
        sys.exit(f"self-test '{' '.join(command)}' exited {run.returncode}")
    try:
        report = last_report(run.stdout)
    except ValueError as exc:
        sys.exit(str(exc))
    if not report.get("ok"):
        sys.exit("the self-test did not report ok")
    module = report.get("onnxruntime_module", "")
    if args.root and module and not module.startswith(args.root.rstrip("/") + "/"):
        sys.exit(f"the self-test loaded ONNX Runtime from {module}, outside {args.root}")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
