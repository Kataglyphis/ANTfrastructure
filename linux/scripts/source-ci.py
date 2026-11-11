#!/usr/bin/env python3
"""Preserve and audit the Hub's five source workflows; source CI never replaces image or hardware acceptance."""

import argparse
from pathlib import Path

from source_ci import combined, dispatch, fetch, linux, windows
from source_ci.common import DEFAULT_REPO


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    specs = {
        "dispatch": (dispatch.run, ("head", "branch", "output")),
        "fetch": (fetch.run, ("dispatch", "directory", "root")),
        "audit-linux": (linux.run, ("root", "head", "run", "jobs", "tree-binding", "log-dir", "output")),
        "audit-windows": (windows.run, ("zip", "api", "prior-proof", "root", "output")),
        "audit-all": (combined.run, ("dispatch", "directory", "linux", "windows", "output")),
    }
    for command, (callback, names) in specs.items():
        sub = commands.add_parser(command)
        sub.set_defaults(callback=callback)
        for name in names:
            sub.add_argument("--" + name, type=str if name in ("head", "branch") else Path, required=True)
        if command == "dispatch":
            sub.add_argument("--repo", default=DEFAULT_REPO)
    args = parser.parse_args()
    args.callback(args)


if __name__ == "__main__":
    main()
