#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""A quality-report.toml `kind = "pattern"` row that carries `max` fails when it matches more often.
docs/code-quality-tooling.md#pattern-limits-pattern-limits"""

import argparse
import os
import re
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_scope
from quality_report import load_config
from quality_report_text import pattern_hits
from quality_report_tree import Context

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))


def limited_rows(config: dict[str, object]) -> list[tuple[dict[str, object], int]]:
    """The pattern rows with a `max`; a `max` that is no whole number of zero or more is a ValueError."""
    rows = config.get("metric", [])
    found = []
    for row in rows if isinstance(rows, list) else []:
        if not isinstance(row, dict) or row.get("kind") != "pattern" or "max" not in row:
            continue
        limit = row["max"]
        # bool is an int in Python, and `max = true` is a typo, not a limit of 1.
        if isinstance(limit, bool) or not isinstance(limit, int) or limit < 0:
            raise ValueError(f"metric {row.get('name', '?')!r}: max must be a whole number >= 0, got {limit!r}")
        found.append((row, limit))
    return found


def grade(ctx: Context, row: dict[str, object], limit: int) -> bool:
    """True when the row holds its limit; every match is printed with its file and line when it does not."""
    name = str(row.get("name", "?"))
    hits = pattern_hits(ctx, row)
    if len(hits) <= limit:
        print(f"OK: {name}: {len(hits)} match(es), at most {limit}")
        return True
    sys.stderr.write(f"FAIL: {name}: {len(hits)} match(es) of /{row['pattern']}/, at most {limit} allowed\n")
    for rel, number, line in hits:
        sys.stderr.write(f"  {rel}:{number}: {line.strip()}\n")
    return False


def main() -> int:
    ap = argparse.ArgumentParser(description="Fail on a quality-report.toml pattern row over its max.")
    ap.add_argument("--root", default=None, help="the repository to grade (default: this repo)")
    args = ap.parse_args()
    try:
        root = gate_scope.resolve_root(args.root, ROOT)
    except gate_scope.ScopeError as exc:
        return gate_scope.die(exc)
    print("=== pattern limits (quality-report.toml rows with max) ===", flush=True)
    config, problems = load_config(root)
    try:
        rows = [] if problems else limited_rows(config)
    except ValueError as exc:
        problems = [str(exc)]
    if problems:
        for problem in problems:
            sys.stderr.write(f"FAIL: {problem}\n")
        return 1
    if not rows:
        print("OK: no pattern row carries max - nothing to enforce")
        return 0
    with tempfile.TemporaryDirectory() as work:
        ctx = Context(root, ROOT, work, config)
        try:
            verdicts = [grade(ctx, row, limit) for row, limit in rows]
        except (KeyError, ValueError, re.error) as exc:
            sys.stderr.write(f"FAIL: a pattern row is malformed: {exc}\n")
            return 1
    return 0 if all(verdicts) else 1


if __name__ == "__main__":
    sys.exit(main())
