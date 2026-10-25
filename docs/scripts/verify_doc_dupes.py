#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""Docs duplication gate (docs/INDEX.md: one owner per passage): cross-file paragraphs sharing too many 8-word shingles; --against-hub grades a consumer's pages against the hub's."""

from __future__ import annotations

import argparse
import itertools
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import TypeAlias

DocUnit: TypeAlias = tuple[str, int]
Shingle: TypeAlias = tuple[str, ...]
Owners: TypeAlias = dict[Shingle, set[DocUnit]]
Texts: TypeAlias = dict[DocUnit, str]
DocPair: TypeAlias = tuple[DocUnit, DocUnit]
AllowedPair: TypeAlias = tuple[int, DocUnit, DocUnit, str]
Finding: TypeAlias = tuple[int, DocUnit, DocUnit, tuple[int, str] | None]
HubPair: TypeAlias = tuple[int, DocUnit, DocUnit]
AllowKey: TypeAlias = frozenset[str] | tuple[str, ...]

# HUB_ROOT is where the gate lives, REPO_ROOT the tree it grades (--root): docs/code-quality-tooling.md#the-scan-root-contract
HUB_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = HUB_ROOT
DOCS = REPO_ROOT / "docs"
ALLOW_FILE = Path(__file__).with_name("doc-dupes.allow")
ALLOW_FMT = "a | b | budget | reason"

sys.path.insert(0, str(HUB_ROOT / "linux" / "scripts"))
import gate_scope
from quality_allow import iter_rows

ROOT_DOCS = ("README.md", "AGENTS.md")

# Records, not rules: they narrate the same work on purpose and are never edited for a gate.
SKIP_MARKERS = ("archive", "refactor-backlog", "CHANGELOG")

SHINGLE = 8
MIN_WORDS = SHINGLE + 4
# A shingle held by more paragraphs than this is vocabulary, not a copied passage.
MAX_OWNERS = 5
DEFAULT_THRESHOLD = 12

WORD = re.compile(r"[a-z0-9]+")
FENCE = "`" * 3

HUB_ALLOW_NAME = "doc-dupes-hub.allow"
HUB_ALLOW_FMT = "consumer page | hub page | budget | reason"
# Hub pages are indexed under this prefix, so no consumer path can name one.
HUB_TAG = "hub:"
HUB_ADVICE = ("The hub owns these passages: replace the consumer's copy with a link to the hub "
              "page (docs/INDEX.md maps topic to page). If the overlap is deliberate, add the pair "
              f"to <root>/{HUB_ALLOW_NAME} with a budget and a reason.")


def paragraphs(path: Path) -> list[str]:
    """Prose paragraphs only: no code fences, tables, headings, HTML comments, badges or images."""
    out: list[str] = []
    buf: list[str] = []
    fence = False
    for line in path.read_text(encoding="utf-8").split("\n"):
        if line.lstrip().startswith(FENCE):
            fence = not fence
            continue
        if fence or line.startswith(("|", "#", "<!--", "-->", "[![", "![")):
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
    """The hub's curated page set (changing it re-budgets every pair), or every tracked page for a consumer."""
    if gate_scope.is_hub(str(REPO_ROOT), str(HUB_ROOT)):
        paths = [REPO_ROOT / n for n in ROOT_DOCS]
        paths += sorted(DOCS.glob("*.md"))
    else:
        paths = [REPO_ROOT / rel
                 for rel in gate_scope.tracked(str(REPO_ROOT), ["*.md"])]
    return [
        p
        for p in paths
        if p.is_file() and not any(m in p.name for m in SKIP_MARKERS)
    ]


def load_allow(fmt: str = ALLOW_FMT, ordered: bool = False) -> dict[AllowKey, tuple[int, str]]:
    """The shared reader's rows folded onto the file pair: unordered here, (consumer, hub) under --against-hub."""
    allow: dict[AllowKey, tuple[int, str]] = {}
    at: dict[AllowKey, int] = {}
    for pair, budget, why, n in iter_rows(str(ALLOW_FILE), 2, fmt):
        key = tuple(pair) if ordered else frozenset(pair)
        if key in allow:
            print(f"ERROR: {ALLOW_FILE.name}:{n}: duplicate row for "
                  f"{' <-> '.join(sorted(key))} (first at line {at[key]}); keep one",
                  file=sys.stderr)
            raise SystemExit(2)
        allow[key] = (budget, why)
        at[key] = n
    return allow


def _index_paragraphs(
    files: list[Path], root: Path | None = None, prefix: str = "",
) -> tuple[Owners, Texts]:
    """(owners, texts): which paragraphs hold each 8-word shingle, and each paragraph's text for reporting."""
    owners: Owners = defaultdict(set)
    texts: Texts = {}
    for path in files:
        rel = prefix + path.relative_to(root or REPO_ROOT).as_posix()
        for i, para in enumerate(paragraphs(path)):
            words = WORD.findall(para.lower())
            if len(words) < MIN_WORDS:
                continue
            texts[(rel, i)] = para
            for j in range(len(words) - SHINGLE + 1):
                owners[tuple(words[j:j + SHINGLE])].add((rel, i))
    return owners, texts


def _collect_shared(owners: Owners) -> Counter[DocPair]:
    """Cross-file paragraph-pair counts, skipping vocabulary shingles and same-file pairs."""
    shared: Counter[DocPair] = Counter()
    for holders in owners.values():
        if 1 < len(holders) <= MAX_OWNERS:
            for a, b in itertools.combinations(sorted(holders), 2):
                if a[0] != b[0]:
                    shared[(a, b)] += 1
    return shared


def _print_report(
    args: argparse.Namespace, files: list[Path], texts: Texts, allowed: list[AllowedPair],
) -> None:
    """The --report listing: what was scanned, then every allowed pair."""
    print(f"scanned {len(texts)} paragraphs in {len(files)} files "
          f"(threshold {args.threshold} shared {SHINGLE}-word shingles)\n")
    for n, a, b, why in allowed:
        print(f"  allowed {n:4d}  {a[0]}  <->  {b[0]}   ({why})")
    if allowed:
        print()


def _print_findings(findings: list[Finding], texts: Texts, advice: str = "") -> None:
    """Every pair over its budget, with both excerpts and what to do about it."""
    print(f"docs duplication gate: {len(findings)} copied passage(s)\n", file=sys.stderr)
    for n, a, b, budget in findings:
        over = f", over its budget of {budget[0]}" if budget else ""
        print(f"  {n} shared shingles{over}", file=sys.stderr)
        print(f"    {a[0]}:  {texts[a][:150]}", file=sys.stderr)
        print(f"    {b[0]}:  {texts[b][:150]}\n", file=sys.stderr)
    print(advice or "Give the passage ONE owner and link to it from the other page "
          f"(docs/INDEX.md decides which). If the overlap is deliberate, add it to "
          f"{ALLOW_FILE.name} with a budget and a reason.", file=sys.stderr)


def _print_bookkeeping(stale: list[AllowKey]) -> int:
    """The stale half of the allow contract: a row whose overlap is gone fails."""
    if not stale:
        return 0
    print(f"docs duplication gate: {len(stale)} stale allowlist entr(ies)\n", file=sys.stderr)
    for k in stale:
        print(f"  {' <-> '.join(sorted(k))} no longer overlaps -- remove it from "
              f"{ALLOW_FILE.name}", file=sys.stderr)
    return 1


def _hub_pages() -> list[Path]:
    """Every tracked page of the hub this gate ships in, records excluded: what a consumer links instead of restating."""
    rels = gate_scope.tracked(str(HUB_ROOT), ["*.md"])
    gate_scope.assert_non_empty(rels, str(HUB_ROOT), ["*.md"], "refuse", "doc-dupes --against-hub")
    return [HUB_ROOT / rel for rel in rels if not any(m in Path(rel).name for m in SKIP_MARKERS)]


def _hub_pairs(files: list[Path], threshold: int) -> tuple[list[HubPair], Texts]:
    """(pairs, texts): consumer paragraph <-> hub paragraph over the threshold, each as (n, consumer, hub)."""
    owners, texts = _index_paragraphs(files)
    hub_owners, hub_texts = _index_paragraphs(_hub_pages(), HUB_ROOT, HUB_TAG)
    for shingle, holders in hub_owners.items():
        owners[shingle] |= holders
    texts.update(hub_texts)
    pairs = []
    for (a, b), n in _collect_shared(owners).items():
        if n <= threshold or a[0].startswith(HUB_TAG) == b[0].startswith(HUB_TAG):
            continue
        consumer, hub = (a, b) if b[0].startswith(HUB_TAG) else (b, a)
        pairs.append((n, consumer, hub))
    return sorted(pairs, reverse=True), texts


def _against_hub(args: argparse.Namespace, files: list[Path]) -> int:
    """--against-hub: a consumer passage restating a hub page fails; off until <root>/doc-dupes-hub.allow exists."""
    global ALLOW_FILE
    if gate_scope.is_hub(str(REPO_ROOT), str(HUB_ROOT)):
        return gate_scope.die(gate_scope.ScopeError("--against-hub grades a consumer's --root; the hub is its own reference"))
    ALLOW_FILE = REPO_ROOT / HUB_ALLOW_NAME
    seeded = ALLOW_FILE.is_file()
    off = f"doc-dupes --against-hub: OFF for {REPO_ROOT} until {HUB_ALLOW_NAME} exists (seed it empty)"
    if not seeded and not args.report:
        print(f"{off}; --report lists what it would find.")
        return 0
    try:
        pairs, texts = _hub_pairs(files, args.threshold)
    except gate_scope.ScopeError as exc:
        return gate_scope.die(exc)
    allow = load_allow(HUB_ALLOW_FMT, ordered=True) if seeded else {}
    used: set[tuple[str, str]] = set()
    findings = []
    for n, consumer, hub in pairs:
        key = (consumer[0], hub[0][len(HUB_TAG):])
        budget = allow.get(key)
        if budget and n <= budget[0]:
            used.add(key)
        else:
            findings.append((n, consumer, hub, budget))
    if not seeded:
        print(f"{off}; {len(findings)} passage(s) restate a hub page.")
        if findings:
            _print_findings(findings, texts, HUB_ADVICE)
        return 0
    if findings:
        _print_findings(findings, texts, HUB_ADVICE)
        return 1
    if _print_bookkeeping(sorted(set(allow) - used)):
        return 1
    print(f"doc-dupes --against-hub OK: {len(files)} page(s) restate no hub page over "
          f"{args.threshold} shared {SHINGLE}-word shingles ({len(allow)} allowlisted pair(s)).")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Verify docs are free of copied passages.")
    ap.add_argument("--threshold", type=int, default=DEFAULT_THRESHOLD,
                    help=f"shared shingles that constitute duplication (default {DEFAULT_THRESHOLD})")
    ap.add_argument("--report", action="store_true",
                    help="list every pair over the threshold, allowed ones included")
    ap.add_argument("--root", metavar="DIR",
                    help="grade this checkout instead of the gate's own repo;"
                         " the budget file is then <root>/doc-dupes.allow")
    ap.add_argument("--against-hub", action="store_true",
                    help="grade --root's pages against this hub's pages instead of against each other;"
                         f" budgets in <root>/{HUB_ALLOW_NAME}, and off until that file exists")
    args = ap.parse_args()

    global REPO_ROOT, DOCS, ALLOW_FILE
    try:
        REPO_ROOT = Path(gate_scope.resolve_root(args.root, str(HUB_ROOT)))
    except gate_scope.ScopeError as exc:
        return gate_scope.die(exc)
    DOCS = REPO_ROOT / "docs"
    if not gate_scope.is_hub(str(REPO_ROOT), str(HUB_ROOT)):
        ALLOW_FILE = REPO_ROOT / "doc-dupes.allow"

    try:
        files = collect()
    except gate_scope.ScopeError as exc:
        return gate_scope.die(exc)
    if not files:
        print("ERROR: no Markdown found to check", file=sys.stderr)
        return 2
    if args.against_hub:
        return _against_hub(args, files)

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
