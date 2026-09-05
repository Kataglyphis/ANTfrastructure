#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""verify_doc_dupes.py -- the docs duplication gate.

Why this exists
---------------
``docs/INDEX.md`` opens with the reason: on 2026-08-11 one Dev Drive command
existed in three places, all three were wrong the same way, and the page that
had it right was never consulted. Copying is what caused it.

That rule was written down and then enforced by nobody. Three rounds of manual
de-duplication in one day each declared the tree clean, and each was measuring
*verbatim lines* -- the wrong instrument, because prose gets reflowed. A
paragraph reworded across two pages shares no whole line while still being the
same paragraph. This finds those.

How
---
Every paragraph is reduced to its set of 8-word shingles (code fences, tables
and headings excluded). Two paragraphs in DIFFERENT files sharing more than the
threshold are reported. Shingles owned by many files are ignored: a phrase that
appears everywhere is vocabulary, not duplication.

Some overlap is correct and permanent -- a rule page states the rule, a
mechanism page explains the mechanism, and both name the same thing. Those pairs
live in ``doc-dupes.allow`` with a budget and a reason, so a *deliberate* twin
stays quiet while a *regression* past its budget fails.

No network; the one project import is the shared allowlist reader
(``linux/scripts/quality_allow.py``). Safe for hooks and CI.

Usage:  python3 docs/scripts/verify_doc_dupes.py [--report] [--threshold N]
Exit:   0 = clean, 1 = findings, 2 = usage/tree error.
"""

from __future__ import annotations

import argparse
import itertools
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DOCS = REPO_ROOT / "docs"
ALLOW_FILE = Path(__file__).with_name("doc-dupes.allow")
ALLOW_FMT = "a | b | budget | reason"

sys.path.insert(0, str(REPO_ROOT / "linux" / "scripts"))
from quality_allow import iter_rows  # noqa: E402

ROOT_DOCS = ("README.md", "AGENTS.md")

# Records, not rules: these narrate the same work on purpose and must never be
# edited to satisfy a gate.
SKIP_MARKERS = ("archive", "refactor-backlog", "CHANGELOG")

SHINGLE = 8
MIN_WORDS = SHINGLE + 4
# A shingle shared by more than this many paragraphs is shared vocabulary
# ("the build fails with", "see the section below"), not a copied passage.
MAX_OWNERS = 5
DEFAULT_THRESHOLD = 12

WORD = re.compile(r"[a-z0-9]+")
FENCE = "`" * 3


def paragraphs(path: Path) -> list[str]:
    """Prose paragraphs only: no code fences, tables, headings or HTML."""
    out: list[str] = []
    buf: list[str] = []
    fence = False
    for line in path.read_text(encoding="utf-8").split("\n"):
        if line.lstrip().startswith(FENCE):
            fence = not fence
            continue
        if fence or line.startswith(("|", "#", "<!--", "-->")):
            continue
        if not line.strip():
            if buf:
                out.append(" ".join(buf))
                buf = []
        else:
            buf.append(line.strip())
    if buf:
        out.append(" ".join(buf))
    return out


def collect() -> list[Path]:
    paths = [REPO_ROOT / n for n in ROOT_DOCS]
    paths += sorted(DOCS.glob("*.md"))
    return [
        p
        for p in paths
        if p.is_file() and not any(m in p.name for m in SKIP_MARKERS)
    ]


def load_allow() -> dict[frozenset[str], tuple[int, str]]:
    """The shared reader's rows folded onto the UNORDERED file pair this gate keys on."""
    allow: dict[frozenset[str], tuple[int, str]] = {}
    at: dict[frozenset[str], int] = {}
    for pair, budget, why, n in iter_rows(str(ALLOW_FILE), 2, ALLOW_FMT):
        key = frozenset(pair)
        if key in allow:
            print(f"ERROR: {ALLOW_FILE.name}:{n}: duplicate row for "
                  f"{' <-> '.join(sorted(key))} (first at line {at[key]}); keep one",
                  file=sys.stderr)
            raise SystemExit(2)
        allow[key] = (budget, why)
        at[key] = n
    return allow


def _index_paragraphs(files):
    """Shingle-index every prose paragraph in scope.

    Returns (owners, texts): which paragraphs hold each 8-word shingle, and the
    text of each paragraph for later reporting.
    """
    owners: dict[tuple, set[tuple[str, int]]] = defaultdict(set)
    texts: dict[tuple[str, int], str] = {}
    for path in files:
        rel = path.relative_to(REPO_ROOT).as_posix()
        for i, para in enumerate(paragraphs(path)):
            words = WORD.findall(para.lower())
            if len(words) < MIN_WORDS:
                continue
            texts[(rel, i)] = para
            for j in range(len(words) - SHINGLE + 1):
                owners[tuple(words[j:j + SHINGLE])].add((rel, i))
    return owners, texts


def _collect_shared(owners) -> Counter:
    """Turn the shingle index into cross-file paragraph-pair counts.

    A shingle held by more than MAX_OWNERS paragraphs is shared vocabulary, and
    same-file pairs are a page restating itself -- neither is duplication here.
    """
    shared: Counter = Counter()
    for holders in owners.values():
        if 1 < len(holders) <= MAX_OWNERS:
            for a, b in itertools.combinations(sorted(holders), 2):
                if a[0] != b[0]:
                    shared[(a, b)] += 1
    return shared


def _print_report(args, files, texts, allowed) -> None:
    """The --report listing: what was scanned, then every allowed pair."""
    print(f"scanned {len(texts)} paragraphs in {len(files)} files "
          f"(threshold {args.threshold} shared {SHINGLE}-word shingles)\n")
    for n, a, b, why in allowed:
        print(f"  allowed {n:4d}  {a[0]}  <->  {b[0]}   ({why})")
    if allowed:
        print()


def _print_findings(findings, texts) -> None:
    """Every pair over its budget, with both excerpts and what to do about it."""
    print(f"docs duplication gate: {len(findings)} copied passage(s)\n", file=sys.stderr)
    for n, a, b, budget in findings:
        over = f", over its budget of {budget[0]}" if budget else ""
        print(f"  {n} shared shingles{over}", file=sys.stderr)
        print(f"    {a[0]}:  {texts[a][:150]}", file=sys.stderr)
        print(f"    {b[0]}:  {texts[b][:150]}\n", file=sys.stderr)
    print("Give the passage ONE owner and link to it from the other page "
          f"(docs/INDEX.md decides which). If the overlap is deliberate, add it to "
          f"{ALLOW_FILE.name} with a budget and a reason.", file=sys.stderr)


def _print_bookkeeping(stale) -> int:
    """The stale half of the allow contract: a row whose overlap is gone fails."""
    if not stale:
        return 0
    print(f"docs duplication gate: {len(stale)} stale allowlist entr(ies)\n", file=sys.stderr)
    for k in stale:
        print(f"  {' <-> '.join(sorted(k))} no longer overlaps -- remove it from "
              f"{ALLOW_FILE.name}", file=sys.stderr)
    return 1


def main() -> int:
    ap = argparse.ArgumentParser(description="Verify docs are free of copied passages.")
    ap.add_argument("--threshold", type=int, default=DEFAULT_THRESHOLD,
                    help=f"shared shingles that constitute duplication (default {DEFAULT_THRESHOLD})")
    ap.add_argument("--report", action="store_true",
                    help="list every pair over the threshold, allowed ones included")
    args = ap.parse_args()

    files = collect()
    if not files:
        print("ERROR: no Markdown found to check", file=sys.stderr)
        return 2

    owners, texts = _index_paragraphs(files)
    shared = _collect_shared(owners)

    allow = load_allow()
    used: set[frozenset[str]] = set()
    findings, allowed = [], []
    for (a, b), n in shared.items():
        if n <= args.threshold:
            continue
        key = frozenset((a[0], b[0]))
        budget = allow.get(key)
        if budget and n <= budget[0]:
            used.add(key)
            allowed.append((n, a, b, budget[1]))
            continue
        findings.append((n, a, b, budget))

    findings.sort(reverse=True, key=lambda f: f[0])
    allowed.sort(reverse=True, key=lambda f: f[0])

    if args.report:
        _print_report(args, files, texts, allowed)

    if findings:
        _print_findings(findings, texts)
        return 1

    if _print_bookkeeping(sorted(k for k in allow if k not in used)):
        return 1

    print(f"docs duplication gate OK: {len(texts)} paragraphs in {len(files)} files, "
          f"no passage over {args.threshold} shared {SHINGLE}-word shingles "
          f"({len(allow)} allowlisted pair(s)).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
