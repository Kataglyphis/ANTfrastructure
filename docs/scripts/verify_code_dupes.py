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

Clone families
--------------
A family is ONE block and the files that all hold it -- keyed by the block's
owner set, not by file adjacency. Clustering on adjacency merged every family
that shared a single file and once printed one useless "88 files" blob.

Run ``--baseline`` once to freeze what exists today; after that NEW or GROWING
duplication fails, and so does a budget the measurement has dropped below or a
row whose pair no longer overlaps -- the four-way rule of quality_allow, kept
local because the key here is an UNORDERED file pair. A gate that fires on day
one about work nobody plans to undo is a gate people learn to ignore.

Windows files are out of scope on purpose: that lane has its own backlog.

No network, and one project import: the shared allow reader
(``linux/scripts/quality_allow.py``). Safe for hooks and CI.

``--baseline`` rewrites the WHOLE file, so the parser refuses it together with
``--kind``: scoping the rewrite would drop every other kind's curated rows --
236 of today's 241 for ``--kind md``.

Usage:  python3 docs/scripts/verify_code_dupes.py [--report] [--baseline]
                                                  [--threshold N] [--kind K]
Exit:   0 = clean, 1 = findings, 2 = usage/tree error.
docs/code-quality-tooling.md#contract-tightening-2026-09-03-code-dupes-env-knobs
"""

from __future__ import annotations

import argparse
import itertools
import re
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
ALLOW_FILE = Path(__file__).with_name("code-dupes.allow")
ALLOW_FMT = "a | b | budget | reason"

sys.path.insert(0, str(REPO_ROOT / "linux" / "scripts"))
from quality_allow import iter_rows  # noqa: E402

# Never scanned: vendored trees, generated output, the Windows lane (own
# backlog), and the records that narrate the same work on purpose.
# "third_party" joined 2026-09-07: the external/ -> third_party/ submodule move
# (2026-09-05) renamed the vendored tree but not this exclusion, so a checkout
# with initialized submodules scanned DocumANTation's own prose for
# ContainerHub duplication. "external" stays for the leftover husk.
SKIP_DIRS = {".git", "external", "third_party", "node_modules", "windows", "out", "archive",
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
# A clone family is one block held by >2 files; below this it is a coincidence.
FAMILY_MIN_SHINGLES = 5
FAMILY_MAX_REPORTED = 10

STRING = re.compile(r"""("([^"\\]|\\.)*"|'([^'\\]|\\.)*')""")
VARIABLE = re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*(:[-=+?][^}]*)?\}|\$[A-Za-z_][A-Za-z0-9_]*")
NUMBER = re.compile(r"\b\d+(\.\d+)?\b")
TOKEN = re.compile(r"[A-Za-z_][A-Za-z0-9_.-]*|\$V|\"S\"|\bN\b|[^\s\w]")
SHELL_FUNC = re.compile(r"^([A-Za-z_][A-Za-z0-9_:-]*)\s*\(\)\s*\{\s*$")
DOCKER_INSTR = re.compile(r"^\s*(FROM|RUN|COPY|ADD|ARG|ENV|WORKDIR|ENTRYPOINT|CMD|LABEL|USER|VOLUME|EXPOSE|HEALTHCHECK|SHELL|ONBUILD|STOPSIGNAL)\b",
                          re.IGNORECASE)


# Spellings the shell treats as identical. Folding them is free accuracy: a copy
# that swapped [[ ]] for [ ], or backticks for $(), is still a copy.
BRACKET = re.compile(r"\[\[(.*?)\]\]")
BACKTICK = re.compile(r"`([^`]*)`")


def canonicalise(line: str) -> str:
    line = BRACKET.sub(r"[\1]", line)
    return BACKTICK.sub(r"$(\1)", line)


def normalise_lines(text: str) -> list[str]:
    """Per-line normalised form, for measuring CONTIGUOUS runs."""
    out = []
    for raw in text.split("\n"):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        line = STRING.sub('"S"', line)
        line = VARIABLE.sub("$V", line)
        line = NUMBER.sub("N", line)
        line = canonicalise(line)
        out.append(" ".join(TOKEN.findall(line)))
    return out


def longest_common_run(a: list[str], b: list[str]) -> int:
    """Longest run of consecutive identical normalised lines."""
    if not a or not b:
        return 0
    best = 0
    prev = [0] * (len(b) + 1)
    for i in range(1, len(a) + 1):
        cur = [0] * (len(b) + 1)
        ai = a[i - 1]
        for j in range(1, len(b) + 1):
            if ai == b[j - 1]:
                cur[j] = prev[j - 1] + 1
                if cur[j] > best:
                    best = cur[j]
        prev = cur
    return best


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
        line = canonicalise(line)
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


def _file_kind(name: str) -> str | None:
    if name.endswith(".sh"):
        return "shell"
    if name.startswith("Dockerfile"):
        return "docker"
    if name.endswith(".md"):
        return "md"
    return None


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
        kind = _file_kind(name)
        if kind and not (kind == "md" and path in doc_gate_scope):
            found.append((path, kind))
    return found


UNIT_READERS = {"shell": shell_units, "docker": docker_units, "md": md_units}


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


def _index_units(files):
    """Shingle-index every unit in scope.

    Returns (owners, heads, texts, unit_lines, kind_of): which units hold each
    shingle, which shingles OPEN a unit (they make the best excerpts), and the
    text and normalised lines of each unit for later reporting.
    """
    owners: dict[tuple, set[tuple[str, int]]] = defaultdict(set)
    heads: set[tuple] = set()
    texts: dict[tuple[str, int], str] = {}
    unit_lines: dict[tuple[str, int], list[str]] = {}
    kind_of: dict[str, str] = {}
    for path, kind in files:
        rel = path.relative_to(REPO_ROOT).as_posix()
        kind_of[rel] = kind
        for line_no, body in UNIT_READERS[kind](path):
            toks = normalise(body)
            if len(toks) < MIN_TOKENS:
                continue
            texts[(rel, line_no)] = " ".join(body.split())
            unit_lines[(rel, line_no)] = normalise_lines(body)
            for j in range(len(toks) - SHINGLE + 1):
                sh = tuple(toks[j:j + SHINGLE])
                owners[sh].add((rel, line_no))
                if j == 0:
                    heads.add(sh)
    return owners, heads, texts, unit_lines, kind_of


def _collect_shared(owners, heads, kind_of):
    """Turn the shingle index into pair counts, spread and clone families.

    Returns (shared, spread, families, suppressed). A family is keyed by the
    BLOCK's owner set, never by file adjacency -- keying on adjacency once
    collapsed most of the tree into one meaningless "88 files" family.
    """
    shared: Counter = Counter()
    spread: Counter = Counter()
    # A family is keyed by the BLOCK's owner set, never by file adjacency: one
    # file in two families must not merge them (that printed "88 files" once).
    families: dict[frozenset[str], list] = {}
    suppressed = 0
    for shingle, holders in owners.items():
        if len(holders) > MAX_OWNERS:
            # The perverse property, now turned into the tool's best feature: a
            # block copied into TEN files is worth extracting far more than one
            # copied into two, yet it is exactly the one the owner cutoff hides.
            # Keep the widest ones as a ranked worklist instead of dropping them.
            suppressed += 1
            spread[frozenset(h[0] for h in holders)] += 1
            continue
        if len(holders) > 1:
            # Same-FILE pairs are included: two twin helpers in one file were
            # invisible before (proven with a probe), and that is exactly the
            # copy-paste a reviewer scrolling one file also misses.
            # EXCEPT Dockerfiles: they have no include or function mechanism, so
            # a repeated RUN mount preamble is not extractable and reporting it
            # is noise the reader can do nothing about.
            for a, b in itertools.combinations(sorted(holders), 2):
                if a[0] == b[0] and kind_of.get(a[0]) == "docker":
                    continue
                shared[(a, b)] += 1
            held_by = frozenset(h[0] for h in holders)
            if len(held_by) > 2:
                entry = families.get(held_by)
                if entry is None:
                    families[held_by] = [1, shingle, sorted(holders)]
                else:
                    entry[0] += 1
                    if shingle in heads and entry[1] not in heads:
                        entry[1], entry[2] = shingle, sorted(holders)
    return shared, spread, families, suppressed


def _print_report(args, files, texts, allowed, runs, spread):
    """The --report listing: every allowed pair, then the widely-copied blocks."""
    print(f"scanned {len(texts)} units in {len(files)} files "
          f"(threshold {args.threshold} shared {SHINGLE}-token shingles)\n")
    for n, a, b, why in allowed:
        print(f"  allowed {n:4d}  run={runs.get((a, b), 0):3d}  "
              f"{a[0]}  <->  {b[0]}   ({why})")
    if allowed:
        print()
    # Rank by BLOCK SIZE, not by how many files hold it. One shingle across
    # 34 files is `set -euo pipefail` -- idiom. Ten shingles across 8 files
    # is a copied helper. Sorting by file count buries the second under the
    # first (learned the hard way on the 199-shingle usage() pair).
    WIDE_MIN_SHINGLES = 5
    wide = [(cnt, fs) for fs, cnt in spread.items()
            if len(fs) > MAX_OWNERS and cnt >= WIDE_MIN_SHINGLES]
    wide.sort(reverse=True, key=lambda w: (w[0], len(w[1])))
    if wide:
        print(f"widely-copied blocks ({len(wide)} group(s) of >= "
              f"{WIDE_MIN_SHINGLES} shingles held by > {MAX_OWNERS} files) -- "
              f"the highest-leverage extractions:\n")
        for cnt, fs in wide[:10]:
            print(f"  {cnt:3d} shingles x {len(fs):2d} files: "
                  f"{', '.join(sorted(fs)[:4])}"
                  f"{' ...' if len(fs) > 4 else ''}")
        print()


def _print_bookkeeping(shrunk, stale, measured, threshold) -> int:
    """Allow rows whose budget no longer equals reality: shrunk (paste the printed
    row) or stale (delete the row). Returns 1 if either list is non-empty."""
    if shrunk:
        print(f"code duplication gate: {len(shrunk)} allowlist budget(s) above the "
              f"measurement -- record the new budget\n", file=sys.stderr)
        for key, n, (was, why) in sorted(shrunk, key=lambda s: sorted(s[0])):
            names = sorted(key)
            fa, fb = names[0], names[-1]
            print(f"  {fa} <-> {fb} shrank from {was} to {n} -- record the new budget "
                  f"{n} in {ALLOW_FILE.name}:\n    {fa} | {fb} | {n} | {why}\n",
                  file=sys.stderr)
    if stale:
        print(f"code duplication gate: {len(stale)} stale allowlist entr(ies)\n", file=sys.stderr)
        for k in sorted(stale, key=sorted):
            print(f"  {' <-> '.join(sorted(k))} is no longer over the threshold "
                  f"({measured.get(k, (0,))[0]} shared, threshold {threshold}) -- "
                  f"remove it from {ALLOW_FILE.name}", file=sys.stderr)
    return 1 if shrunk or stale else 0


def _print_families(ranked, stream) -> None:
    """One family = one BLOCK and the >2 files that all hold it, capped, with an
    excerpt so the reader can act."""
    for cnt, held, sh, at in ranked[:FAMILY_MAX_REPORTED]:
        excerpt = " ".join(sh)
        print(f"  clone family: ONE block of {cnt} shingle(s), "
              f"held by {len(held)} files", file=stream)
        print(f"    block  {excerpt[:110]}{' ...' if len(excerpt) > 110 else ''}",
              file=stream)
        print(f"    at     {', '.join(f'{f}:{ln}' for f, ln in at)}", file=stream)
    if len(ranked) > FAMILY_MAX_REPORTED:
        print(f"  ... and {len(ranked) - FAMILY_MAX_REPORTED} smaller famil(ies)",
              file=stream)


def _print_findings(findings, runs, texts, ranked) -> None:
    print(f"code duplication gate: {len(findings)} copied block(s)\n", file=sys.stderr)
    for n, a, b, budget in findings:
        over = f", over its budget of {budget[0]}" if budget else ""
        print(f"  {n} shared shingles{over}, longest identical run "
              f"{runs.get((a, b), 0)} line(s)", file=sys.stderr)
        print(f"    {a[0]}:{a[1]}  {texts[a][:140]}", file=sys.stderr)
        print(f"    {b[0]}:{b[1]}  {texts[b][:140]}\n", file=sys.stderr)
    _print_families(ranked, sys.stderr)
    if ranked:
        print("", file=sys.stderr)
    print("Give the block ONE owner (a shared helper in 01-core, or the "
          f"canonical page) and call it from the other. If the twin is "
          f"deliberate, add it to {ALLOW_FILE.name} with a budget and a reason.",
          file=sys.stderr)


def _write_baseline(per_file, allow) -> int:
    """Rewrite the allow file: rows sorted by budget, existing reasons kept
    verbatim, new rows dated; only the header comments survive."""
    lines = [
        "# code-dupes.allow -- deliberate twins, with a budget and a reason.",
        "# Format: fileA | fileB | budget | reason",
        "# Generated by --baseline; every entry below is PRE-EXISTING duplication",
        "# frozen so the gate only reports NEW or GROWING copies. The budget must",
        "# EQUAL the measurement: a copy that shrank fails until its row says so.",
        "",
    ]
    fresh = f"baseline {time.strftime('%Y-%m-%d')}, not yet reviewed"
    for key, (n, _a, _b) in sorted(per_file.items(), key=lambda kv: -kv[1][0]):
        names = sorted(key)
        fa, fb = names[0], (names[1] if len(names) > 1 else names[0])
        lines.append(f"{fa} | {fb} | {n} | {allow.get(key, (0, fresh))[1]}")
    ALLOW_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {ALLOW_FILE.name}: {len(per_file)} pair(s) frozen as budgets")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Verify code is free of copied blocks.")
    ap.add_argument("--threshold", type=int, default=DEFAULT_THRESHOLD,
                    help=f"shared shingles that constitute duplication (default {DEFAULT_THRESHOLD})")
    ap.add_argument("--report", action="store_true",
                    help="list every pair over the threshold, allowed ones included")
    # Mutually exclusive, not a hand-written guard: --baseline rewrites the WHOLE
    # allow file, so scoping it would silently discard every other kind's rows.
    scope = ap.add_mutually_exclusive_group()
    scope.add_argument("--baseline", action="store_true",
                       help=f"rewrite {ALLOW_FILE.name} to freeze today's duplication as budgets"
                            " (whole file; cannot be scoped with --kind)")
    scope.add_argument("--kind", choices=sorted(UNIT_READERS), action="append",
                       help="restrict to one kind (repeatable); default all")
    args = ap.parse_args()

    kinds = set(args.kind) if args.kind else set(UNIT_READERS)
    files = [(p, k) for p, k in collect() if k in kinds]
    if not files:
        print("ERROR: nothing in scope to check", file=sys.stderr)
        return 2

    owners, heads, texts, unit_lines, kind_of = _index_units(files)

    shared, spread, families, suppressed = _collect_shared(owners, heads, kind_of)

    # Collapse unit pairs to FILE pairs: the allowlist and the reader both think
    # in files, and one copied helper usually shows up as several unit pairs.
    measured: dict[frozenset[str], tuple[int, tuple, tuple]] = {}
    for (a, b), n in shared.items():
        key = frozenset((a[0], b[0]))   # 1 element when the twin is same-file
        if key not in measured or n > measured[key][0]:
            measured[key] = (n, a, b)
    per_file = {k: v for k, v in measured.items() if v[0] > args.threshold}

    allow = {k: v for k, v in load_allow().items()
             if all(_file_kind(Path(f).name) in kinds for f in k)}

    if args.baseline:
        return _write_baseline(per_file, allow)

    findings, allowed, shrunk = [], [], []
    for key, (n, a, b) in per_file.items():
        budget = allow.get(key)
        if budget and n <= budget[0]:
            allowed.append((n, a, b, budget[1]))
            if n < budget[0]:
                shrunk.append((key, n, budget))
            continue
        findings.append((n, a, b, budget))

    # Rank by the longest CONTIGUOUS identical run, not by scattered shingle
    # overlap: 199 scattered shingles across two sibling CLIs' usage() heredocs
    # is not extractable, while 20 consecutive identical lines is a helper
    # waiting to be born. Shingle count stays as the tie-breaker.
    runs = {}
    for _n, a, b, _x in list(findings) + list(allowed):
        runs[(a, b)] = longest_common_run(unit_lines.get(a, []), unit_lines.get(b, []))
    findings.sort(reverse=True, key=lambda f: (runs.get((f[1], f[2]), 0), f[0]))
    allowed.sort(reverse=True, key=lambda f: (runs.get((f[1], f[2]), 0), f[0]))

    ranked = sorted(((cnt, held, sh, anchor)
                     for held, (cnt, sh, anchor) in families.items()
                     if cnt >= FAMILY_MIN_SHINGLES),
                    key=lambda f: (-f[0], -len(f[1]), sorted(f[1])))

    if args.report:
        _print_report(args, files, texts, allowed, runs, spread)

    stale = [k for k in allow if k not in per_file]
    bookkeeping = _print_bookkeeping(shrunk, stale, measured, args.threshold)

    if findings:
        _print_findings(findings, runs, texts, ranked)
        return 1

    if bookkeeping:
        return 1

    _print_families(ranked, sys.stdout)
    print(f"code duplication gate OK: {len(texts)} units in {len(files)} files, "
          f"no block over {args.threshold} shared {SHINGLE}-token shingles "
          f"({len(allow)} allowlisted pair(s); {suppressed} shingle(s) suppressed "
          f"as idiom at >{MAX_OWNERS} owners).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
