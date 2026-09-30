#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""Code duplication gate on normalised tokens, so renamed clones match: docs/code-quality-tooling.md#contract-tightening-2026-09-03-code-dupes-env-knobs"""

from __future__ import annotations

import argparse
import itertools
import re
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

# HUB_ROOT is where the gate lives, REPO_ROOT the tree it grades (--root): docs/code-quality-tooling.md#the-scan-root-contract
HUB_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = HUB_ROOT
# Follows the root too, so a consumer's ratchet lands in its own diff.
ALLOW_FILE = Path(__file__).with_name("code-dupes.allow")
ALLOW_FMT = "a | b | budget | reason"

sys.path.insert(0, str(HUB_ROOT / "linux" / "scripts"))
from quality_allow import iter_rows  # noqa: E402
import gate_scope  # noqa: E402

# Never scanned: vendored trees, generated output, and records that narrate the same work on purpose.
SKIP_DIRS = {".git", "external", "third_party", "node_modules", "out", "archive",
             "_build", "dist", "sphinx-kataglyphis-theme", "logs",
             # Third-party and generated: nothing here is ours to de-duplicate.
             ".venv", "venv", "site-packages", ".tox", "license-assets",
             # Tool caches: a hand-run pytest plants identical README.md files.
             ".pytest_cache", "__pycache__", ".dart_tool",
             "source_templates", "deps"}
SKIP_NAME_MARKERS = ("archive", "backlog", "CHANGELOG")
# Per-kind skips: windows scripts are in scope, only its prose and Dockerfiles keep the exemption.
KIND_SKIP_DIRS = {"shell": {"windows"}, "docker": {"windows"}, "md": {"windows"}}

# Code repeats itself more than prose, so the window is wider than the prose gate's 8 words.
SHINGLE = 12
MIN_TOKENS = SHINGLE + 6
# A shingle owned by more units than this is idiom (set -euo pipefail, arg-parse loops), not duplication.
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
# PowerShell opens a body on the header line or the next, so the brace is optional.
PS_FUNC = re.compile(r"^\s*(?:function|filter)\s+([^\s({]+)\s*(?:\([^)]*\))?\s*\{?\s*$",
                     re.IGNORECASE)
# Blanked first: an unbalanced brace in a <# #> comment would swallow the rest of the file.
PS_BLOCK_COMMENT = re.compile(r"<#.*?#>", re.S)
# $env:PATH and $script:Foo are one variable each, so a renamed copy still matches.
PS_SCOPE_VAR = re.compile(r"\$(?:global|script|local|private|using|env|variable):",
                          re.IGNORECASE)
DOCKER_INSTR = re.compile(r"^\s*(FROM|RUN|COPY|ADD|ARG|ENV|WORKDIR|ENTRYPOINT|CMD|LABEL|USER|VOLUME|EXPOSE|HEALTHCHECK|SHELL|ONBUILD|STOPSIGNAL)\b",
                          re.IGNORECASE)


# Spellings the shell treats as identical: a copy that swapped [[ ]] for [ ] or backticks for $() is still a copy.
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


def _brace_units(lines: list[str], header: re.Pattern) -> list[tuple[int, str]]:
    """Brace-delimited blocks opened by `header` (shell or PowerShell); everything else is chunked on blank lines."""
    units: list[tuple[int, str]] = []
    i, n = 0, len(lines)
    loose: list[str] = []
    loose_start = 1
    while i < n:
        m = header.match(lines[i])
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


def shell_units(path: Path) -> list[tuple[int, str]]:
    """Shell functions; anything outside one is chunked on blank lines."""
    return _brace_units(path.read_text(encoding="utf-8", errors="replace").split("\n"),
                        SHELL_FUNC)


def ps_units(path: Path) -> list[tuple[int, str]]:
    """PowerShell functions and filters; block comments are blanked with their newlines, so line numbers hold."""
    text = PS_BLOCK_COMMENT.sub(lambda m: "\n" * m.group(0).count("\n"),
                                path.read_text(encoding="utf-8", errors="replace"))
    return _brace_units(text.split("\n"), PS_FUNC)


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
    # Before the Dockerfile prefix: Dockerfile.EolAttributes.Tests.ps1 is a Pester suite.
    if name.endswith((".ps1", ".psm1")):
        return "ps"
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
        name = path.name
        if any(m.lower() in name.lower() for m in SKIP_NAME_MARKERS):
            continue
        kind = _file_kind(name)
        if kind is None or (SKIP_DIRS | KIND_SKIP_DIRS.get(kind, set())) & set(rel.parts):
            continue
        if not (kind == "md" and path in doc_gate_scope):
            found.append((path, kind))
    return found


UNIT_READERS = {"shell": shell_units, "ps": ps_units,
                "docker": docker_units, "md": md_units}
# Per-kind folding before normalisation, never applied to the text the report quotes.
KIND_FOLD = {"ps": lambda text: PS_SCOPE_VAR.sub("$", text)}


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
    """(owners, heads, texts, unit_lines, kind_of): shingle holders, unit-opening shingles for excerpts, and report data."""
    owners: dict[tuple, set[tuple[str, int]]] = defaultdict(set)
    heads: set[tuple] = set()
    texts: dict[tuple[str, int], str] = {}
    unit_lines: dict[tuple[str, int], list[str]] = {}
    kind_of: dict[str, str] = {}
    for path, kind in files:
        rel = path.relative_to(REPO_ROOT).as_posix()
        kind_of[rel] = kind
        fold = KIND_FOLD.get(kind)
        for line_no, body in UNIT_READERS[kind](path):
            folded = fold(body) if fold else body
            toks = normalise(folded)
            if len(toks) < MIN_TOKENS:
                continue
            texts[(rel, line_no)] = " ".join(body.split())
            unit_lines[(rel, line_no)] = normalise_lines(folded)
            for j in range(len(toks) - SHINGLE + 1):
                sh = tuple(toks[j:j + SHINGLE])
                owners[sh].add((rel, line_no))
                if j == 0:
                    heads.add(sh)
    return owners, heads, texts, unit_lines, kind_of


def _collect_shared(owners, heads, kind_of):
    """(shared, spread, families, suppressed); a family is keyed by the block's owner set, never by file adjacency."""
    shared: Counter = Counter()
    spread: Counter = Counter()
    families: dict[frozenset[str], list] = {}
    suppressed = 0
    for shingle, holders in owners.items():
        if len(holders) > MAX_OWNERS:
            # Kept as a ranked worklist: a block in ten files is the best extraction, yet the cutoff hides it.
            suppressed += 1
            spread[frozenset(h[0] for h in holders)] += 1
            continue
        if len(holders) > 1:
            # Same-file pairs count too, except in Dockerfiles, which have nothing to extract a repeat into.
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
    # Rank by block size, not file count: one shingle in 34 files is idiom, ten in eight a copied helper.
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
    """Allow rows whose budget no longer equals reality, shrunk or stale; returns 1 if any."""
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
    """Each family (one block held by more than two files), capped, with an excerpt to act on."""
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


def _dispatch_mode(args, owners, texts, unit_lines, per_file, allow):
    """Modes that answer instead of judging, kept out of main() for its complexity budget; None means judge."""
    if args.explain:
        return _explain_pair(args.explain, owners, texts, unit_lines)
    if args.baseline:
        return _write_baseline(per_file, allow)
    return None

def _explain_targets(paths, texts):
    """The one or two files --explain was given, or None after saying why not."""
    if len(paths) > 2:
        print("ERROR: --explain takes one or two paths", file=sys.stderr)
        return None
    want = [Path(x).as_posix() for x in paths]
    a_file = want[0]
    b_file = want[1] if len(want) == 2 else want[0]
    known = {rel for rel, _line in texts}
    for f in {a_file, b_file}:
        if f not in known:
            print(f"ERROR: {f} is not a scanned unit-bearing file", file=sys.stderr)
            print("       (paths are repo-relative, e.g. linux/scripts/preflight.sh)",
                  file=sys.stderr)
            return None
    return a_file, b_file


def _explain_counts(owners, a_file, b_file):
    """Shared shingles per unit pair, split into counted and dropped-as-idiom."""
    counted: Counter = Counter()
    idiom: Counter = Counter()
    for _sh, holders in owners.items():
        left = sorted(h for h in holders if h[0] == a_file)
        right = sorted(h for h in holders if h[0] == b_file)
        if not left or not right:
            continue
        for x in left:
            for y in right:
                if x < y:   # skip a unit against itself and the mirror of a seen pair
                    (idiom if len(holders) > MAX_OWNERS else counted)[(x, y)] += 1
    return counted, idiom

def _explain_pair(paths, owners, texts, unit_lines) -> int:
    """What a pair shares unit by unit, including the shingles the idiom cutoff drops from the count."""
    pair = _explain_targets(paths, texts)
    if pair is None:
        return 2
    a_file, b_file = pair

    counted, idiom = _explain_counts(owners, a_file, b_file)

    if not counted and not idiom:
        print(f"{a_file} <-> {b_file}: nothing shared")
        return 0

    label = a_file if a_file == b_file else f"{a_file} <-> {b_file}"
    print(f"{label}")
    print(f"  MAX_OWNERS={MAX_OWNERS}; a shingle held by more units is dropped as idiom")
    print()
    for (x, y), n in sorted(counted.items(), key=lambda kv: -kv[1]):
        hidden = idiom.get((x, y), 0)
        extra = f"  (+{hidden} dropped as idiom)" if hidden else ""
        print(f"  {n:4d} shingle(s)  line {x[1]} <-> line {y[1]}{extra}")
        run = longest_common_run(unit_lines.get(x, []), unit_lines.get(y, []))
        print(f"        longest identical run: {run} line(s)")
        print(f"        A: {texts.get(x, '')[:120]}")
        print(f"        B: {texts.get(y, '')[:120]}")
    only_idiom = {k: v for k, v in idiom.items() if k not in counted}
    if only_idiom:
        total = sum(only_idiom.values())
        print()
        print(f"  {total} further shingle(s) across {len(only_idiom)} unit pair(s) are"
              f" held by more than {MAX_OWNERS} units and never counted.")
    return 0

def _write_baseline(per_file, allow) -> int:
    """Rewrite the allow file sorted by budget, keeping existing reasons and dating new rows."""
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


def _build_parser() -> argparse.ArgumentParser:
    """The CLI surface, lifted out of main() so main() stays control flow."""
    ap = argparse.ArgumentParser(description="Verify code is free of copied blocks.")
    ap.add_argument("--threshold", type=int, default=DEFAULT_THRESHOLD,
                    help=f"shared shingles that constitute duplication (default {DEFAULT_THRESHOLD})")
    ap.add_argument("--report", action="store_true",
                    help="list every pair over the threshold, allowed ones included")
    # --baseline rewrites the whole allow file, so scoping it with --kind would drop every other kind's rows.
    scope = ap.add_mutually_exclusive_group()
    scope.add_argument("--baseline", action="store_true",
                       help=f"rewrite {ALLOW_FILE.name} to freeze today's duplication as budgets"
                            " (whole file; cannot be scoped with --kind)")
    scope.add_argument("--kind", choices=sorted(UNIT_READERS), action="append",
                       help="restrict to one kind (repeatable); default all")
    ap.add_argument("--root", metavar="DIR",
                    help="grade this checkout instead of the gate's own repo;"
                         " the budget file is then <root>/code-dupes.allow")
    ap.add_argument("--explain", nargs="+", metavar="FILE",
                    help="say WHAT one pair shares: the overlapping units, their"
                         " line numbers and how much the idiom cutoff hides."
                         " One path for a self-pair, two for a cross-file pair")
    return ap

def _apply_root(arg) -> None:
    """Re-point the graded tree and its budget file; an unusable root ends the run via SystemExit."""
    global REPO_ROOT, ALLOW_FILE
    try:
        root = Path(gate_scope.resolve_root(arg, str(HUB_ROOT)))
    except gate_scope.ScopeError as exc:
        raise SystemExit(gate_scope.die(exc)) from None
    REPO_ROOT = root
    if not gate_scope.is_hub(str(root), str(HUB_ROOT)):
        ALLOW_FILE = root / "code-dupes.allow"


def main() -> int:
    args = _build_parser().parse_args()
    _apply_root(args.root)

    kinds = set(args.kind) if args.kind else set(UNIT_READERS)
    files = [(p, k) for p, k in collect() if k in kinds]
    if not files:
        print("ERROR: nothing in scope to check", file=sys.stderr)
        return 2

    owners, heads, texts, unit_lines, kind_of = _index_units(files)

    shared, spread, families, suppressed = _collect_shared(owners, heads, kind_of)

    # Collapse unit pairs to file pairs, as the allowlist and the reader think in files.
    measured: dict[frozenset[str], tuple[int, tuple, tuple]] = {}
    for (a, b), n in shared.items():
        key = frozenset((a[0], b[0]))   # 1 element when the twin is same-file
        if key not in measured or n > measured[key][0]:
            measured[key] = (n, a, b)
    per_file = {k: v for k, v in measured.items() if v[0] > args.threshold}

    allow = {k: v for k, v in load_allow().items()
             if all(_file_kind(Path(f).name) in kinds for f in k)}

    dispatched = _dispatch_mode(args, owners, texts, unit_lines, per_file, allow)
    if dispatched is not None:
        return dispatched

    findings, allowed, shrunk = [], [], []
    for key, (n, a, b) in per_file.items():
        budget = allow.get(key)
        if budget and n <= budget[0]:
            allowed.append((n, a, b, budget[1]))
            if n < budget[0]:
                shrunk.append((key, n, budget))
            continue
        findings.append((n, a, b, budget))

    # Rank by the longest contiguous identical run, which is extractable where scattered overlap is not.
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
