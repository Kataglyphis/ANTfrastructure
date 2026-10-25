#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""The tests a project runs on its installed cp3XYt wheel: its pyproject.toml table, and a pytest run that keeps the GIL off.

`table PYPROJECT [--format json|argv]` (any 3.11+): exit 0 printed, 1 no table, 2 invalid. `run [--site DIR]... -- ARGS`:
pytest in this free-threaded interpreter, failed when the GIL is on afterwards. See docs/python-ci.md#the-suite-on-the-installed-wheel
"""

import argparse
import json
import os
import re
import site
import sys
import sysconfig
from pathlib import Path, PurePosixPath, PureWindowsPath

TABLE = "free-threaded-wheel-tests"
KEYS = ("extra", "copy", "env", "isolated", "pytest-args")
ENV_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def _is_strings(value: object) -> bool:
    """Whether value is a list of strings."""
    return isinstance(value, list) and all(isinstance(v, str) for v in value)


# Each key's type check and the words its refusal uses; only a table that passes them all is read further.
CHECKS = {
    "extra": (lambda v: isinstance(v, str), "a string"),
    "copy": (lambda v: _is_strings(v) and bool(v) and all(v), "a non-empty list of paths"),
    "env": (lambda v: isinstance(v, dict) and all(isinstance(x, str) for x in v.values()), "a table of strings"),
    "isolated": (lambda v: isinstance(v, bool), "true or false"),
    "pytest-args": (_is_strings, "a list of strings"),
}


def _outside(path: str) -> bool:
    """Whether a copy path is absolute or climbs out of the checkout, in either path flavour."""
    posix, win = PurePosixPath(path), PureWindowsPath(path)
    return posix.is_absolute() or win.is_absolute() or bool(win.drive) or ".." in posix.parts or ".." in win.parts


def _problems(table: dict) -> list[str]:
    """What is wrong with the table: unknown keys, wrong types, a copy that leaves the checkout, a line break anywhere."""
    found = [f"unknown key '{k}' (known: {', '.join(KEYS)})" for k in table if k not in KEYS]
    wrong = [f"'{k}' must be {words}" for k, (ok, words) in CHECKS.items() if k in table and not ok(table[k])]
    if "copy" not in table:
        wrong.append("'copy' must be a non-empty list of paths")
    if wrong:
        return found + wrong
    env = table.get("env", {})
    found += [f"'copy' path '{c}' must stay inside the checkout" for c in table["copy"] if _outside(c)]
    found += [f"'env' name '{n}' is not NAME" for n in env if not ENV_NAME.fullmatch(n)]
    values = [table.get("extra", ""), *table["copy"], *env, *env.values(), *table.get("pytest-args", [])]
    if any("\n" in v or "\r" in v for v in values):
        found.append("no value may hold a line break")
    return found


def read_table(pyproject: str) -> tuple[int, dict | str]:
    """(0, the table with its defaults), (1, why there is none) or (2, why it is invalid)."""
    import tomllib

    path = Path(pyproject)
    if not path.is_file():
        return 1, f"no {path}"
    try:
        with path.open("rb") as fh:
            tool = tomllib.load(fh).get("tool", {}).get("antfrastructure", {})
    except tomllib.TOMLDecodeError as exc:
        return 2, f"{path} is not valid TOML: {exc}"
    # Any other table under [tool.antfrastructure] is a misspelt name, which would otherwise read as no tests at all.
    others = sorted(set(tool) - {TABLE})
    if others:
        return 2, f"[tool.antfrastructure] in {path} holds {', '.join(others)}; the one table is '{TABLE}'"
    if TABLE not in tool:
        return 1, f"no [tool.antfrastructure.{TABLE}] in {path}"
    table = tool[TABLE]
    problems = _problems(table) if isinstance(table, dict) else ["it must be a table"]
    if problems:
        return 2, f"[tool.antfrastructure.{TABLE}] in {path}: " + "; ".join(problems)
    return 0, {
        "extra": table.get("extra", ""),
        "copy": table["copy"],
        "env": table.get("env", {}),
        "isolated": table.get("isolated", False),
        "pytest-args": table.get("pytest-args", []),
    }


def as_argv(table: dict) -> list[str]:
    """The table as test-free-threaded-wheel.sh's own arguments."""
    argv = ["--extra", table["extra"]] if table["extra"] else []
    for c in table["copy"]:
        argv += ["--copy", c]
    for name, value in table["env"].items():
        argv += ["--env", f"{name}={value}"]
    if table["isolated"]:
        argv.append("--isolated")
    return [*argv, "--", *table["pytest-args"]]


def print_table(pyproject: str, fmt: str) -> int:
    """Print the table as JSON or argv lines, or why there is none."""
    code, table = read_table(pyproject)
    if code:
        print(table)
    else:
        if not isinstance(table, dict):
            raise RuntimeError("validated wheel test table has no fields")
        if fmt == "argv":
            print("\n".join(as_argv(table)))
        else:
            print(json.dumps(table))
    return code


def prepend_sites(sites: list[str], head: int) -> None:
    """Put each site directory, with its .pth files, at sys.path[head:], where PYTHONPATH would go, but under -I too."""
    for directory in reversed(sites):
        before = list(sys.path)
        site.addsitedir(directory)
        added = [p for p in sys.path if p not in before]
        sys.path[:] = before[:head] + added + before[head:]


def run(sites: list[str], args: list[str]) -> int:
    """Run pytest here with ARGS; return its exit code, or 1 when the tests passed but left the GIL enabled."""
    if not sysconfig.get_config_var("Py_GIL_DISABLED"):
        print(f"ERROR: {sys.executable} is not a free-threaded interpreter", file=sys.stderr)
        return 2
    if sys._is_gil_enabled():
        print("ERROR: the GIL is enabled before any test (-X gil=1 or PYTHON_GIL=1?)", file=sys.stderr)
        return 2
    # As python -m pytest: the run directory, not this script's, leads sys.path unless -I dropped both.
    if not sys.flags.safe_path:
        sys.path[0] = os.getcwd()
    prepend_sites(sites, 0 if sys.flags.safe_path else 1)
    import pytest

    code = int(pytest.main(["-p", "no:cacheprovider", *args]))
    version = ".".join(map(str, sys.version_info[:3]))
    if sys._is_gil_enabled():
        print(f"ERROR: the GIL was enabled during the tests on free-threaded {version}; the warnings summary names the module",
              file=sys.stderr)
        return code or 1
    if code == 0:
        print(f"the GIL stayed disabled through the tests on free-threaded {version}")
    return code


def main(argv: list[str]) -> int:
    """Dispatch table and run."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    table = sub.add_parser("table")
    table.add_argument("pyproject")
    table.add_argument("--format", choices=("json", "argv"), default="json")
    runner = sub.add_parser("run")
    runner.add_argument("--site", action="append", default=[])
    runner.add_argument("args", nargs="*")
    parsed = parser.parse_args(argv)
    if parsed.command == "table":
        return print_table(parsed.pyproject, parsed.format)
    return run(parsed.site, parsed.args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
