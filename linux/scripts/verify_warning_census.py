#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""Hold a lane's compiler warnings in the repository's own code at a committed count per flag (CON295 (c), owner D11).

Usage: verify_warning_census.py --lane <name> --census <file> [--write] <build log>...
docs/code-quality-tooling.md#the-warning-census
"""
from __future__ import annotations

import argparse
import posixpath
import re
import sys
from pathlib import Path

_TAIL = r" warning: (?P<text>.*?)\s*(?:\[(?P<tag>[^\]]+)\])?\s*$"
# GCC and clang: path:line:col: warning: text [-Wflag], after any CI timestamp or ninja prefix.
WARNING = re.compile(r"(?P<path>(?:[A-Za-z]:)?[^\s:][^:\s]*):(?P<line>\d+):(?:\d+:)?" + _TAIL)
# clang-cl: path(line,col): warning: text [-Wflag]; a drive-letter path may hold spaces (C:\Program Files\...).
WARNING_CL = re.compile(r"(?P<path>[A-Za-z]:[\\/][^:(]*?|[^\s:(][^\s:(]*)\((?P<line>\d+)(?:,\d+)?\) ?:" + _TAIL)
# Clang colours its diagnostics when it runs on a terminal, which splits a warning line with escape codes.
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
# A compile command or its ninja/make progress line: proof the log compiled something.
COMPILED = re.compile(
    r"Building (?:C|CXX) object|\[\d+/\d+\] Building|(?:^|\s)(?:c\+\+|g\+\+|clang\+\+|gcc|clang)\S* .*-c "
    r"|[\s\\/]clang-cl(?:\.exe)? .*\s[-/]c(?:\s|$)"
)
# Code this repository does not own: vendored trees, fetched dependencies, the toolchain's headers.
FOREIGN = re.compile(r"(^|/)(third_party|_deps|external|vendor)/|^/(usr|opt)/")
# The checkout in a container or on a runner: Linux's, then the family's Windows container mounts and a Windows runner's.
WORKSPACE = re.compile(
    r"^(?:/workspace|/__w/[^/]+/[^/]+|/home/runner/work/[^/]+/[^/]+|[A-Za-z]:/ws(?:-mnt)?|[A-Za-z]:/a/[^/]+/[^/]+)/"
)
ABSOLUTE = re.compile(r"^(?:/|[A-Za-z]:/)")
UNNAMED = "-W(unnamed)"


class CensusError(ValueError):
    """A census file or a log the gate cannot grade; the lane then says so instead of passing."""


def own_path(raw: str) -> str | None:
    """The repository-relative path of a warning in its own code, or None for foreign code."""
    path = raw.replace("\\", "/")
    # One header reached as Src/a/../b/x.h and Src/b/x.h is one warning, and a/../third_party/ is foreign.
    path = posixpath.normpath(path)
    path = WORKSPACE.sub("", path)
    path = path.removeprefix("./")
    if FOREIGN.search(path) or ABSOLUTE.match(path):
        return None
    return path


def count_warnings(logs: list[Path]) -> tuple[dict[str, int], int]:
    """({flag: unique own warnings}, compile lines seen); a header's warning repeats per unit, so it counts once."""
    seen: set[tuple[str, str, str]] = set()
    compiled = 0
    for log in logs:
        for raw in log.read_text(encoding="utf-8", errors="replace").splitlines():
            line = ANSI.sub("", raw)
            compiled += bool(COMPILED.search(line))
            match = WARNING.search(line) or WARNING_CL.search(line)
            tag = match.group("tag") if match else None
            # A clang-tidy or analyzer finding names its check, not a -W flag; it is not the compiler's warning.
            path = own_path(match.group("path")) if match and (tag is None or tag.startswith("-W")) else None
            if match and path:
                seen.add((path, match.group("line"), tag or UNNAMED))
    counts: dict[str, int] = {}
    for _path, _line, flag in seen:
        counts[flag] = counts.get(flag, 0) + 1
    return counts, compiled


def load_census(path: Path) -> dict[tuple[str, str], int]:
    """`<lane> | <flag> | <count>` rows -> {(lane, flag): count}."""
    rows: dict[tuple[str, str], int] = {}
    if not path.exists():
        return rows
    for num, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) != 3 or not parts[2].isdigit():
            raise CensusError(f"{path.name}:{num}: expected '<lane> | <flag> | <count>', got {line!r}")
        if (parts[0], parts[1]) in rows:
            raise CensusError(f"{path.name}:{num}: a second row for {parts[0]} {parts[1]}; one of them is unread")
        rows[(parts[0], parts[1])] = int(parts[2])
    return rows


def grade(lane: str, counts: dict[str, int], census: dict[tuple[str, str], int]) -> list[str]:
    """Every flag whose count moved from the census row; a drop fails too, so the baseline cannot rot."""
    problems = []
    flags = {flag for (row_lane, flag) in census if row_lane == lane} | set(counts)
    for flag in sorted(flags):
        now, was = counts.get(flag, 0), census.get((lane, flag), 0)
        if now > was:
            problems.append(f"[{lane}] {flag} GREW from {was} to {now}; fix the new warning(s)")
        elif now < was:
            action = "delete the row" if now == 0 else f"lower the row to {now}"
            problems.append(f"[{lane}] {flag} is down to {now} from {was}; {action} in this commit")
    return problems


def write_lane(path: Path, lane: str, counts: dict[str, int]) -> None:
    """Rewrite this lane's rows from the counts, keeping every other lane's rows and the comments."""
    kept = []
    if path.exists():
        for raw in path.read_text(encoding="utf-8").splitlines():
            parts = [p.strip() for p in raw.split("|")]
            if not (len(parts) == 3 and parts[0] == lane):
                kept.append(raw)
    rows = [f"{lane} | {flag} | {counts[flag]}" for flag in sorted(counts) if counts[flag]]
    path.write_text("\n".join(kept + rows) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--lane", required=True)
    parser.add_argument("--census", required=True, type=Path)
    parser.add_argument("--write", action="store_true", help="rewrite this lane's rows from the logs")
    parser.add_argument("logs", nargs="+", type=Path)
    args = parser.parse_args(argv)
    try:
        counts, compiled = count_warnings(args.logs)
        if not compiled:
            raise CensusError("the log(s) compiled nothing, so a warning count over them grades nothing")
        if args.write:
            write_lane(args.census, args.lane, counts)
        problems = grade(args.lane, counts, load_census(args.census))
    except (CensusError, OSError) as exc:
        print(f"FAIL: warning census: {exc}", file=sys.stderr)
        return 1
    total = sum(counts.values())
    print(f"warning census [{args.lane}]: {total} own warning(s) over {len(counts)} flag(s), {compiled} compile line(s)")
    for problem in problems:
        print(f"FAIL: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
