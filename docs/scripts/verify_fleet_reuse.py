#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Report Bash and PowerShell overlap across active, owned, nonfork checkouts."""

from __future__ import annotations

import argparse
import sys
from collections import Counter, defaultdict
from pathlib import Path

import verify_code_dupes as dupes
import verify_hub_reuse as hub_reuse


class FleetReuseError(Exception):
    """Incomplete inventory or checkout evidence cannot produce a reuse report."""


def owned_names(path: Path, owner: str, known: set[str], hub_name: str) -> list[str]:
    """Read the GitHub API's filtered full_name rows and prove inventory coverage."""
    if not path.is_file():
        raise FleetReuseError(f"owned repository list is missing: {path}")
    names: list[str] = []
    for line_no, raw in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
        full = raw.strip()
        if not full:
            continue
        parts = full.split("/")
        if len(parts) != 2 or parts[0].casefold() != owner.casefold() or not parts[1]:
            raise FleetReuseError(f"{path}:{line_no}: unexpected repository identity {full!r}")
        name = parts[1]
        if name in names:
            raise FleetReuseError(f"{path}:{line_no}: duplicate repository {full}")
        if name not in known:
            raise FleetReuseError(f"active owned repository {full} has no declared checkout")
        names.append(name)
    if hub_name not in names or len(names) < 2:
        raise FleetReuseError(f"{path}: expected {hub_name} and at least one owned consumer")
    return sorted(names)


def _indexed(roots: dict[str, Path], hub: Path) -> tuple[dupes.Owners, dupes.UnitLines,
                                                         dict[str, int], dict[str, int]]:
    owners: dupes.Owners = defaultdict(set)
    lines: dupes.UnitLines = {}
    scripts: dict[str, int] = {}
    synced_counts: dict[str, int] = {}
    for name, root in sorted(roots.items()):
        synced = set() if root == hub else hub_reuse._shared_check(root, hub)
        files = hub_reuse._scripts(root, synced)
        if root == hub and not files:
            raise FleetReuseError(f"no tracked Bash or PowerShell scripts in hub {hub}")
        index, _, _, unit_lines, _ = dupes.index_units(files, root=root)
        scripts[name] = len(files)
        synced_counts[name] = len(synced)
        for shingle, units in index.items():
            owners[shingle].update((f"{name}/{rel}", line) for rel, line in units)
        lines.update({(f"{name}/{rel}", line): body
                      for (rel, line), body in unit_lines.items()})
    return owners, lines, scripts, synced_counts


def _findings(owners: dupes.Owners, lines: dupes.UnitLines) -> tuple[
    list[tuple[int, int, dupes.Unit, dupes.Unit]], Counter[frozenset[str]], int,
]:
    shared, spread, _, suppressed = dupes.collect_shared(owners, set(), {})
    findings = []
    for (left, right), count in shared.items():
        if count <= dupes.DEFAULT_THRESHOLD or left[0].split("/", 1)[0] == right[0].split("/", 1)[0]:
            continue
        run = dupes.longest_common_run(lines[left], lines[right])
        findings.append((count, run, left, right))
    findings.sort(key=lambda row: (-row[1], -row[0], row[2], row[3]))
    return findings, spread, suppressed


def render(names: list[str], roots: dict[str, Path], hub: Path,
           limit: int) -> str:
    owners, lines, scripts, synced = _indexed(roots, hub)
    findings, spread, suppressed = _findings(owners, lines)
    pairs: Counter[tuple[str, str]] = Counter()
    for _, _, left, right in findings:
        pairs[(left[0].split("/", 1)[0], right[0].split("/", 1)[0])] += 1
    output = ["# Owned fleet Bash and PowerShell reuse", "",
              f"Active owned nonfork repositories scanned: {len(names)}",
              f"Cross-repository overlapping unit pairs: {len(findings)}",
              f"Common idiom shingles suppressed: {suppressed}", "",
              ("Overlap is a refactoring lead, not a failure or proof of equal behavior. "
               "The report cannot detect semantic copies with different token structure."), "",
              "| repository | scripts scanned | synchronized copies excluded |",
              "| --- | ---: | ---: |"]
    output += [f"| {name} | {scripts[name]} | {synced[name]} |" for name in names]
    output += ["", "## Cross-repository pairs", "",
               "| repositories | overlapping units |", "| --- | ---: |"]
    output += [f"| {left} / {right} | {count} |"
               for (left, right), count in sorted(pairs.items(), key=lambda row: (-row[1], row[0]))]
    if not pairs:
        output.append("| none | 0 |")
    output += ["", f"## Highest-overlap units (first {min(limit, len(findings))})", ""]
    for count, run, left, right in findings[:limit]:
        output += [f"- {count} shared shingles, {run} consecutive normalized lines:",
                   f"  `{left[0]}:{left[1]}` and `{right[0]}:{right[1]}`"]
    if len(findings) > limit:
        output.append(f"- {len(findings) - limit} more unit pairs omitted from this bounded report.")
    wide = [(count, files) for files, count in spread.items()
            if count >= dupes.FAMILY_MIN_SHINGLES and
            len({path.split("/", 1)[0] for path in files}) > 1]
    wide.sort(key=lambda row: (-row[0], sorted(row[1])))
    output += ["", "## Widespread blocks above the idiom owner limit", ""]
    for count, files in wide[:20]:
        output.append(f"- {count} shared shingles in {len(files)} files: "
                      + ", ".join(f"`{path}`" for path in sorted(files)[:5]))
    if not wide:
        output.append("_None._")
    return "\n".join(output) + "\n"


def scan(owned: Path, checkouts: dict[str, Path], hub: Path,
         owner: str, hub_name: str, report: Path, limit: int = 100) -> str:
    names = owned_names(owned, owner, set(checkouts), hub_name)
    if limit < 1:
        raise FleetReuseError("--max-findings must be positive")
    logs = (hub / "logs").resolve()
    if not report.resolve().is_relative_to(logs):
        raise FleetReuseError(f"reuse report must be under ignored {logs}")
    roots = {name: Path(dupes.gate_scope.resolve_root(checkouts[name], hub)).resolve()
             for name in names}
    roots[hub_name] = Path(dupes.gate_scope.resolve_root(hub, hub)).resolve()
    result = render(names, roots, hub, limit)
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(result, encoding="utf-8")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--owned-list", required=True,
                        help="one OWNER/REPO per line from the filtered GitHub API inventory")
    parser.add_argument("--checkout", action="append", default=[], metavar="NAME=PATH")
    parser.add_argument("--local-root", metavar="DIR",
                        help="find checkouts named after repositories directly under DIR")
    parser.add_argument("--hub", required=True)
    parser.add_argument("--owner", default="Kataglyphis")
    parser.add_argument("--hub-name", default="ANTfrastructure")
    parser.add_argument("--report", required=True)
    parser.add_argument("--max-findings", type=int, default=100)
    args = parser.parse_args()
    try:
        checkouts = {}
        if args.local_root:
            local_root = Path(args.local_root)
            if not local_root.is_dir():
                raise FleetReuseError(f"--local-root is not a directory: {local_root}")
            checkouts.update({path.name: path for path in local_root.iterdir() if path.is_dir()})
        explicit = set()
        for item in args.checkout:
            name, sep, path = item.partition("=")
            if not sep or not name or not path or name in explicit:
                raise FleetReuseError(f"--checkout expects a unique NAME=PATH, got {item!r}")
            explicit.add(name)
            checkouts[name] = Path(path)
        if args.hub_name not in checkouts:
            raise FleetReuseError(f"--checkout must include {args.hub_name}")
        report = Path(args.report)
        scan(Path(args.owned_list), checkouts, Path(args.hub).resolve(),
             args.owner, args.hub_name, report, args.max_findings)
    except (FleetReuseError, dupes.gate_scope.ScopeError, hub_reuse.HubReuseError,
            OSError, UnicodeError) as exc:
        print(f"ERROR: fleet reuse scan: {exc}", file=sys.stderr)
        return 2
    print(f"fleet reuse: report written to {report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
