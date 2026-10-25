#!/usr/bin/env python3
"""Exercise the Windows ShellCheck command-line cap without ShellCheck itself."""

from __future__ import annotations

import argparse
import io
import json
import subprocess
import sys
from contextlib import redirect_stderr
from pathlib import Path
from typing import Any
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_shellcheck_warnings as gate


def main() -> int:
    files = [f"linux/scripts/{index:02d}-{'x' * 40}.sh" for index in range(4)]
    executable = "shellcheck.exe"
    single_length = len(
        subprocess.list2cmdline([executable, *gate.SHELLCHECK_ARGUMENTS, files[0]])
    )
    limit = single_length
    calls: list[list[str]] = []

    def fake_run(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
        del kwargs
        calls.append(command)
        if len(subprocess.list2cmdline(command)) > limit:
            raise AssertionError(
                "ShellCheck command exceeded the simulated Windows limit"
            )
        if command[1:6] != ["-x", "-f", "json1", "-S", "warning"]:
            raise AssertionError("every batch must retain ShellCheck source following")
        batch = command[1 + len(gate.SHELLCHECK_ARGUMENTS) :]
        body = {
            "comments": [
                {"file": path, "level": "warning", "code": 2034} for path in batch
            ]
        }
        return subprocess.CompletedProcess(command, 1, json.dumps(body), "")

    with (
        patch.object(gate.os, "name", "nt"),
        patch.object(gate, "SHELLCHECK_ARGUMENT_LIMIT", limit),
        patch.object(gate.subprocess, "run", side_effect=fake_run),
    ):
        counts = gate.warnings(executable, files, ".")

    expected = {(path, "SC2034"): 1 for path in files}
    flattened = [
        path
        for command in calls
        for path in command[1 + len(gate.SHELLCHECK_ARGUMENTS) :]
    ]
    assert flattened == files, (
        "batching must keep file order and include every input once"
    )
    assert len(calls) == len(files), (
        "the chosen limit should require one input per invocation"
    )
    assert counts == expected, "findings from every JSON response must be combined"

    diagnostic = io.StringIO()
    with (
        patch.object(gate.gate_scope, "resolve_root", side_effect=gate.gate_scope.ScopeError("bad root")),
        redirect_stderr(diagnostic),
    ):
        try:
            gate.resolve(argparse.Namespace(root="bad", allow=None))
        except SystemExit as exc:
            assert exc.code == 2, "invalid roots must exit with the gate's usage status"
        else:
            raise AssertionError("invalid roots must not return a fake root/allow pair")
    assert diagnostic.getvalue() == "ERROR: bad root\n", (
        "invalid roots must return a named gate error, not a traceback"
    )
    print(f"{len(calls)} bounded runs; {len(counts)} findings merged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
