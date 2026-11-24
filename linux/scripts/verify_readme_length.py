#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""The README rule: a root README.md of at most 100 lines, 700 words and 160 characters a line, or its census rows.

Usage: verify_readme_length.py [--root DIR] [--census FILE] [--write | --seed]
docs/code-quality-tooling.md#readme-length-readme-length
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path
from typing import TypeAlias

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_scope
from verify_doc_prose import Census, CensusError, CensusSpec, load_census, render

HUB = Path(__file__).resolve().parents[2]
HUB_CENSUS = Path("docs/scripts/readme-length.census")
CONSUMER_CENSUS = Path("readme-length.census")
README = "README.md"
LIMIT = 100
WIDTH = 160
LIMITS = {"words": 700, "long-lines": 0, "overflow": 0}
SPEC = CensusSpec("# <page> | <metric> | <value>: a value may only fall, and a row at its limit goes. "
                  "verify_readme_length.py --write lowers the rows.", tuple(LIMITS), frozenset(LIMITS))
RULE = "https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/repository-family.md#the-readme-rule"

# Exempt from words and width: a line of badges, and a line that is one link (also in a list item or as a definition).
IMAGE = r"!\[[^\]]*\]\([^)]*\)"
LINK = r"\[[^\]]*\]\([^)]*\)"
BADGE_LINE = re.compile(rf"^\s*(?:(?:\[{IMAGE}\]\([^)]*\)|{IMAGE})\s*)+$")
LINK_LINE = re.compile(rf"^\s*(?:[-*+]\s+)?(?:{LINK}|<https?://[^>\s]+>|https?://\S+|\[[^\]]+\]:\s+\S+)\s*$")
WORD = re.compile(r"[^\W_]")

Values: TypeAlias = dict[str, int]


def count_lines(path: Path) -> int:
    """Lines as an editor numbers them: a last line without a newline still counts."""
    data = path.read_bytes()
    return data.count(b"\n") + (1 if data and not data.endswith(b"\n") else 0)


def measure(text: str) -> tuple[Values, list[tuple[int, int]]]:
    """Words, and the lines over WIDTH as (number, characters); exempt lines count for neither."""
    words = 0
    wide: list[tuple[int, int]] = []
    for number, raw in enumerate(text.split("\n"), 1):
        line = raw.rstrip("\r")
        if BADGE_LINE.match(line) or LINK_LINE.match(line):
            continue
        words += sum(1 for token in line.split() if WORD.search(token))
        if len(line) > WIDTH:
            wide.append((number, len(line)))
    return {"words": words, "long-lines": len(wide), "overflow": sum(n - WIDTH for _, n in wide)}, wide


def lowered(census: Census, values: Values) -> Census:
    """Each row moved down to its measurement; a row at or under its limit, or of another page, goes."""
    rows: Census = {key: min(was, values[key[1]]) for key, was in census.items() if key[0] == README}
    return {key: value for key, value in rows.items() if value > LIMITS[key[1]]}


def grade(values: Values, census: Census) -> list[str]:
    """A figure with a row rides it, one without meets its limit, and a row with nothing to hold fails."""
    problems = [f"{page}: the {metric} row holds nothing (another page, or at its limit); --write deletes it"
                for (page, metric), was in sorted(census.items()) if page != README or was <= LIMITS[metric]]
    for metric, now in values.items():
        was = census.get((README, metric))
        if was is None:
            if now > LIMITS[metric]:
                problems.append(f"{README}: {metric} is {now}, over the {LIMITS[metric]} "
                                "a README without a row may have")
        elif now > was:
            problems.append(f"{README}: {metric} grew from {was:g} to {now}; move the detail to a docs page")
        elif now < was:
            problems.append(f"{README}: {metric} fell from {was:g} to {now}; lower its row in this commit (--write)")
    return problems


def seed(census_path: Path, values: Values) -> None:
    """A first census: one row for each figure over its limit, so a README within them gets none."""
    if census_path.exists():
        raise CensusError(f"{census_path} exists; --seed writes a first census only, --write lowers this one")
    seeded: Census = {(README, m): float(v) for m, v in values.items() if v > LIMITS[m]}
    census_path.write_text(render(seeded, SPEC), encoding="utf-8")
    print(f"readme-length: seeded {census_path}")


def run(root: Path, census_path: Path, hub: bool, args: argparse.Namespace) -> int:
    readme = root / README
    print(f"=== README length (at most {LIMIT} lines, {LIMITS['words']} words, {WIDTH} characters a line) ===",
          flush=True)
    if not readme.is_file():
        sys.stderr.write(f"FAIL: no README.md at {root}; every repository has one (the README rule: {RULE})\n")
        return 1
    count = count_lines(readme)
    values, wide = measure(readme.read_text(encoding="utf-8", errors="replace"))
    over = f"{README} is {count} lines, over the {LIMIT} the README rule allows, badges included"
    problems = [] if count <= LIMIT else [over]
    if args.seed:
        seed(census_path, values)
    if not census_path.exists():
        if hub:
            raise CensusError(f"{census_path} is missing; the hub grades its README against it")
        print(f"readme-length: words and width OFF for {root} until {census_path.name} exists; --seed writes it")
    else:
        census = load_census(census_path, SPEC)
        if args.write:
            census = lowered(census, values)
            census_path.write_text(render(census, SPEC), encoding="utf-8")
        problems += grade(values, census)
    print(f"{README} is {count} lines, {values['words']} words, {values['long-lines']} line(s) over {WIDTH} characters")
    for problem in problems:
        sys.stderr.write(f"FAIL: {problem}\n")
    if problems:
        sys.stderr.write("".join(f"      {README}:{n}: {chars} characters\n" for n, chars in wide))
        sys.stderr.write(f"      Move procedures, tables and history to docs/ and link them: {RULE}\n")
    return 1 if problems else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    parser.add_argument("--root", help="the repository to grade (default: this hub)")
    parser.add_argument("--census", type=Path, help="the census file (default: docs/scripts/readme-length.census in "
                                                    "the hub, <root>/readme-length.census in a consumer)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--write", action="store_true",
                      help="lower each row to its measurement; never raises or adds one")
    mode.add_argument("--seed", action="store_true",
                      help="write a first census: a row for each figure over its limit")
    args = parser.parse_args(argv)
    try:
        root = Path(gate_scope.resolve_root(args.root, str(HUB)))
        hub = gate_scope.is_hub(str(root), str(HUB))
        return run(root, args.census or root / (HUB_CENSUS if hub else CONSUMER_CENSUS), hub, args)
    except gate_scope.ScopeError as exc:
        return gate_scope.die(exc)
    except (CensusError, OSError) as exc:
        print(f"ERROR: readme-length: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
