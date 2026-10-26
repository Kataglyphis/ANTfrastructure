#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Every RUN of a chain Dockerfile carries its own `LABEL kataglyphis.step=<name>`, so
`nerdctl history` and layer-audit.py name the layer it makes.
docs/code-quality-tooling.md#step-labels-dockerfile-lint"""
import os
import re
import sys
from os import PathLike

from verify_dockerfile_env_order import ROOT, instructions

NAME = re.compile(r"^[a-z0-9][a-z0-9.-]*$")
STEP = re.compile(r"(?:^|\s)kataglyphis\.step=(\S*)")
# These make a layer of their own, so a label before them would name it instead of the RUN.
LAYERED = {"FROM", "RUN", "COPY", "ADD", "WORKDIR"}


def scan(path: str | PathLike[str]) -> list[tuple[int, str]]:
    """(line, problem) per RUN without its own step label, and per bad or repeated name."""
    pending: str | None = None
    seen: dict[str, int] = {}
    out: list[tuple[int, str]] = []
    for line, text in instructions(path):
        parts = text.split(None, 1)
        head = parts[0].upper()
        body = parts[1] if len(parts) > 1 else ""
        if head == "LABEL" and (match := STEP.search(body)):
            name = match.group(1).strip('"')
            if not NAME.match(name):
                out.append((line, f"step name '{name}' is not lowercase kebab-case"))
            elif name in seen:
                out.append((line, f"step name '{name}' is already used on line {seen[name]}"))
            else:
                seen[name] = line
            pending = name
        elif head == "RUN":
            if pending is None:
                out.append((line, "RUN has no LABEL kataglyphis.step=<name> since the previous layer"))
            pending = None
        elif head in LAYERED:
            if pending is not None:
                out.append((line, f"step label '{pending}' is followed by {head}, not by its RUN"))
            pending = None
    return out


def main(argv: list[str]) -> int:
    targets = argv[1:]
    if not targets:
        sys.stderr.write("usage: verify_dockerfile_step_labels.py <Dockerfile>...\n")
        return 2
    bad = 0
    for rel in targets:
        path = rel if os.path.isabs(rel) else os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            sys.stderr.write(f"FAIL: not a file: {rel}\n")
            bad += 1
            continue
        for line, problem in scan(path):
            sys.stderr.write(f"{rel}:{line}: {problem}\n")
            bad += 1
    if bad:
        sys.stderr.write(f"\nSTEP-LABEL LINT FAILED ({bad} finding(s))\n")
        return 1
    print(f"  ok: every RUN names its step ({len(targets)} Dockerfile(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
