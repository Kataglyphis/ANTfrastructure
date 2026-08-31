#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""verify_code_dupes.py -- the CODE duplication gate (shell, Dockerfiles, docs).

Why this exists
---------------
``verify_doc_dupes.py`` guards prose. Nothing guarded code. The tree went
through four manual de-duplication rounds in July 2026 (dedup-pass-2026-07-04,
-05, -05b, -05c), each ending with "the tree is clean" -- and then nothing kept
it that way. A cleanup that is not a gate is a snapshot, and copies creep back.

It also covers the 79 Markdown files ``verify_doc_dupes.py`` never sees: that
gate scans ``docs/*.md`` plus two root files, so nested READMEs (for example
``linux/qnn-sdk/README.md``) were unguarded.

How it differs from the prose gate
----------------------------------
Prose is compared as words. Code cannot be: rename a variable and a verbatim
copy shares no line, yet it is still a copy that will rot in one place only.
So every unit is TOKENISED and NORMALISED first -- comments dropped, string
literals folded to ``"S"``, numbers to ``N``, variable names to ``$V`` -- and
the shingles are taken over those tokens. That finds renamed clones (type-2),
which is the kind this repo actually grows.

Units are the things a human would move: a shell function, a Dockerfile
instruction (continuations joined), a Markdown paragraph.

Deliberate twins
----------------
This repo has a PROTECTED list -- deliberate dedup, standalone bundling,
load-bearing case arms, ARG sprawl, the LiteRT-LM patch stack. Those are
correct and permanent. They live in ``code-dupes.allow`` with a budget and a
reason, exactly like the prose gate, so a deliberate twin stays quiet while a
regression past its budget fails.

Run ``--baseline`` once to freeze what exists today; after that only NEW or
GROWING duplication fails. A gate that fires on day one about work nobody plans
to undo is a gate people learn to ignore.

Windows files are out of scope on purpose: that lane has its own backlog.

No network, no project imports -- safe for hooks and CI.

Usage:  python3 docs/scripts/verify_code_dupes.py [--report] [--baseline]
                                                  [--threshold N] [--kind K]
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
ALLOW_FILE = Path(__file__).with_name("code-dupes.allow")

# Never scanned: vendored trees, generated output, the Windows lane (own
# backlog), and the records that narrate the same work on purpose.
SKIP_DIRS = {".git", "external", "node_modules", "windows", "out", "archive",
             "_build", "dist", "sphinx-kataglyphis-theme", "logs",
             # Third-party and generated: nothing here is ours to de-duplicate.
             ".venv", "venv", "site-packages", ".tox", "license-assets",
             "source_templates", "deps"}
SKIP_NAME_MARKERS = ("archive", "backlog", "CHANGELOG")

# Code repeats itself far more than prose, so the window is wider than the
# prose gate's 8 words: 12 normalised tokens of shell is already a real gesture
# ("if not command -v X >/dev/null 2>&1; then warn ...; return 1; fi").
SHINGLE = 12
MIN_TOKENS = SHINGLE + 6
# A shingle owned by more units than this is idiom, not duplication --
# `set -euo pipefail`, the standard arg-parse while/case, the smoke preamble.
MAX_OWNERS = 6
DEFAULT_THRESHOLD = 10

STRING = re.compile(r"""("([^"\\]|\\.)*"|'([^'\\]|\\.)*')""")
VARIABLE = re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*(:[-=+?][^}]*)?\}|\$[A-Za-z_][A-Za-z0-9_]*")
NUMBER = re.compile(r"\b\d+(\.\d+)?\b")
TOKEN = re.compile(r"[A-Za-z_][A-Za-z0-9_.-]*|\$V|\"S\"|\bN\b|[^\s\w]")
SHELL_FUNC = re.compile(r"^([A-Za-z_][A-Za-z0-9_:-]*)\s*\(\)\s*\{\s*$")
DOCKER_INSTR = re.compile(r"^\s*(FROM|RUN|COPY|ADD|ARG|ENV|WORKDIR|ENTRYPOINT|CMD|LABEL|USER|VOLUME|EXPOSE|HEALTHCHECK|SHELL|ONBUILD|STOPSIGNAL)\b",
                          re.IGNORECASE)


def normalise(text: str) -> list[str]:
    """Fold away the things a copy-paste typically renames."""
    out = []
    for raw in text.split("\n"):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        line = STRING.sub('"S"', line)
        line = VARIABLE.sub("$V", line)
        line = NUMBER.sub("N", line)
        out.extend(TOKEN.findall(line))
    return out


def shell_units(path: Path) -> list[tuple[int, str]]:
    """Shell functions; anything outside one is chunked on blank lines."""
    lines = path.read_text(encoding="utf-8", errors="replace").split("\n")
    units: list[tuple[int, str]] = []
    i, n = 0, len(lines)
    loose: list[str] = []
    loose_start = 1
    while i < n:
        m = SHELL_FUNC.match(lines[i])
        if m:
            if loose:
                units.append((loose_start, "\n".join(loose)))
                loose = []
            start, depth, body = i + 1, 0, []
            while i < n:
                depth += lines[i].count("{") - lines[i].count("}")
                body.append(lines[i])
                i += 1
                if depth <= 0 and len(body) > 1:
                    break
            units.append((start, "\n".join(body)))
            loose_start = i + 1
            continue
        if lines[i].strip():
            if not loose:
                loose_start = i + 1
            loose.append(lines[i])
        elif loose:
            units.append((loose_start, "\n".join(loose)))
            loose = []
        i += 1
    if loose:
        units.append((loose_start, "\n".join(loose)))
    return units


def docker_units(path: Path) -> list[tuple[int, str]]:
    """One unit per instruction, backslash continuations joined."""
    lines = path.read_text(encoding="utf-8", errors="replace").split("\n")
    units: list[tuple[int, str]] = []
    i, n = 0, len(lines)
    while i < n:
        if DOCKER_INSTR.match(lines[i]):
            start, body = i + 1, []
            while i < n:
                body.append(lines[i])
                if not lines[i].rstrip().endswith("\\"):
                    break
                i += 1
            units.append((start, "\n".join(body)))
        i += 1
    return units


def md_units(path: Path) -> list[tuple[int, str]]:
    """Paragraphs, with fenced code blocks dropped (the prose gate's rule)."""
    text = path.read_text(encoding="utf-8", errors="replace")
    text = re.sub(r"```.*?```", "", text, flags=re.S)
    units, buf, start, line_no = [], [], 1, 1
    for raw in text.split("\n"):
        if raw.strip():
            if not buf:
                start = line_no
            buf.append(raw)
        elif buf:
            units.append((start, "\n".join(buf)))
            buf = []
        line_no += 1
    if buf:
        units.append((start, "\n".join(buf)))
    return units


def collect() -> list[tuple[Path, str]]:
    """(path, kind) for everything in scope."""
    doc_gate_scope = {REPO_ROOT / "README.md", REPO_ROOT / "AGENTS.md"}
    doc_gate_scope |= set((REPO_ROOT / "docs").glob("*.md"))

    found: list[tuple[Path, str]] = []
    for path in sorted(REPO_ROOT.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(REPO_ROOT)
        if SKIP_DIRS & set(rel.parts):
            continue
        name = path.name
        if any(m.lower() in name.lower() for m in SKIP_NAME_MARKERS):
            continue
        if name.endswith(".sh"):
            found.append((path, "shell"))
        elif name.startswith("Dockerfile"):
            found.append((path, "docker"))
        elif name.endswith(".md") and path not in doc_gate_scope:
            found.append((path, "md"))
    return found


UNIT_READERS = {"shell": shell_units, "docker": docker_units, "md": md_units}


def load_allow() -> dict[frozenset[str], tuple[int, str]]:
    """`fileA | fileB | budget | reason` -- '#' comments, blank lines ignored."""
    allow: dict[frozenset[str], tuple[int, str]] = {}
    if not ALLOW_FILE.is_file():
        return allow
    for n, raw in enumerate(ALLOW_FILE.read_text(encoding="utf-8").split("\n"), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) != 4 or not parts[2].isdigit():
            print(f"ERROR: {ALLOW_FILE.name}:{n}: expected 'a | b | budget | reason'",
                  file=sys.stderr)
            raise SystemExit(2)
        allow[frozenset((parts[0], parts[1]))] = (int(parts[2]), parts[3])
    return allow


def main() -> int:
    ap = argparse.ArgumentParser(description="Verify code is free of copied blocks.")
    ap.add_argument("--threshold", type=int, default=DEFAULT_THRESHOLD,
                    help=f"shared shingles that constitute duplication (default {DEFAULT_THRESHOLD})")
    ap.add_argument("--report", action="store_true",
                    help="list every pair over the threshold, allowed ones included")
    ap.add_argument("--baseline", action="store_true",
                    help=f"rewrite {ALLOW_FILE.name} to freeze today's duplication as budgets")
    ap.add_argument("--kind", choices=sorted(UNIT_READERS), action="append",
                    help="restrict to one kind (repeatable); default all")
    args = ap.parse_args()

    kinds = set(args.kind) if args.kind else set(UNIT_READERS)
    files = [(p, k) for p, k in collect() if k in kinds]
    if not files:
        print("ERROR: nothing in scope to check", file=sys.stderr)
        return 2

    owners: dict[tuple, set[tuple[str, int]]] = defaultdict(set)
    texts: dict[tuple[str, int], str] = {}
    for path, kind in files:
        rel = path.relative_to(REPO_ROOT).as_posix()
        for line_no, body in UNIT_READERS[kind](path):
            toks = normalise(body)
            if len(toks) < MIN_TOKENS:
                continue
            texts[(rel, line_no)] = " ".join(body.split())
            for j in range(len(toks) - SHINGLE + 1):
                owners[tuple(toks[j:j + SHINGLE])].add((rel, line_no))

    shared: Counter = Counter()
    for holders in owners.values():
        if 1 < len(holders) <= MAX_OWNERS:
            for a, b in itertools.combinations(sorted(holders), 2):
                if a[0] != b[0]:
                    shared[(a, b)] += 1

    # Collapse unit pairs to FILE pairs: the allowlist and the reader both think
    # in files, and one copied helper usually shows up as several unit pairs.
    per_file: dict[frozenset[str], tuple[int, tuple, tuple]] = {}
    for (a, b), n in shared.items():
        if n <= args.threshold:
            continue
        key = frozenset((a[0], b[0]))
        if key not in per_file or n > per_file[key][0]:
            per_file[key] = (n, a, b)

    allow = load_allow()

    if args.baseline:
        lines = [
            "# code-dupes.allow -- deliberate twins, with a budget and a reason.",
            "# Format: fileA | fileB | budget | reason",
            "# Generated by --baseline; every entry below is PRE-EXISTING duplication",
            "# frozen so the gate only reports NEW or GROWING copies. Shrinking one is",
            "# always welcome: lower its budget (or delete the line) when you do.",
            "",
        ]
        for key, (n, _a, _b) in sorted(per_file.items(), key=lambda kv: -kv[1][0]):
            fa, fb = sorted(key)
            lines.append(f"{fa} | {fb} | {n} | baseline 2026-08-31, not yet reviewed")
        ALLOW_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"wrote {ALLOW_FILE.name}: {len(per_file)} pair(s) frozen as budgets")
        return 0

    used: set[frozenset[str]] = set()
    findings, allowed = [], []
    for key, (n, a, b) in per_file.items():
        budget = allow.get(key)
        if budget and n <= budget[0]:
            used.add(key)
            allowed.append((n, a, b, budget[1]))
            continue
        findings.append((n, a, b, budget))

    findings.sort(reverse=True, key=lambda f: f[0])
    allowed.sort(reverse=True, key=lambda f: f[0])

    if args.report:
        print(f"scanned {len(texts)} units in {len(files)} files "
              f"(threshold {args.threshold} shared {SHINGLE}-token shingles)\n")
        for n, a, b, why in allowed:
            print(f"  allowed {n:4d}  {a[0]}  <->  {b[0]}   ({why})")
        if allowed:
            print()

    if findings:
        print(f"code duplication gate: {len(findings)} copied block(s)\n", file=sys.stderr)
        for n, a, b, budget in findings:
            over = f", over its budget of {budget[0]}" if budget else ""
            print(f"  {n} shared shingles{over}", file=sys.stderr)
            print(f"    {a[0]}:{a[1]}  {texts[a][:140]}", file=sys.stderr)
            print(f"    {b[0]}:{b[1]}  {texts[b][:140]}\n", file=sys.stderr)
        print("Give the block ONE owner (a shared helper in 01-core, or the "
              f"canonical page) and call it from the other. If the twin is "
              f"deliberate, add it to {ALLOW_FILE.name} with a budget and a reason.",
              file=sys.stderr)
        return 1

    stale = sorted(k for k in allow if k not in used)
    if stale:
        print(f"code duplication gate: {len(stale)} stale allowlist entr(ies)\n", file=sys.stderr)
        for k in stale:
            print(f"  {' <-> '.join(sorted(k))} no longer overlaps -- remove it from "
                  f"{ALLOW_FILE.name}", file=sys.stderr)
        return 1

    print(f"code duplication gate OK: {len(texts)} units in {len(files)} files, "
          f"no block over {args.threshold} shared {SHINGLE}-token shingles "
          f"({len(allow)} allowlisted pair(s)).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
