#!/usr/bin/env python3
"""Plan --shard K/N from a cost table so each test command's entries share one shard and its baseline runs once per round.

The table maps a test command to its baseline seconds and seconds per entry, read from the gate's cost lines (--from-log).
Does NOT cover runner speed (one table serves every runner), a suite that got slower since the table was written (it keeps
its old weight), or a command the table lacks: those get the median cost and are counted in the plan line.
See docs/code-quality-tooling.md#the-shard-plan
"""
from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import sys
from collections.abc import Iterable, Mapping, Sequence
from typing import NamedTuple, TypeVar

E = TypeVar("E", bound=Mapping[str, object])
_COST_LINE = re.compile(
    r"  cost    wall=(?P<wall>[0-9.]+)s baseline=(?P<base>[0-9.]+)s entries=(?P<n>[0-9]+) test=(?P<test>.+?)\r?$")


class Cost(NamedTuple):
    baseline: float
    per_entry: float


class Piece(NamedTuple):
    first: int
    cost: float
    entries: list[int]


def load_costs(path: str) -> dict[str, Cost]:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    return {cmd: Cost(float(row["baseline"]), float(row["per_entry"])) for cmd, row in data.items()}


def default_cost(costs: Mapping[str, Cost]) -> Cost:
    """The median known command: an unknown suite is assumed typical, neither free nor the slowest."""
    if not costs:
        return Cost(1.0, 1.0)
    return Cost(statistics.median(c.baseline for c in costs.values()),
                statistics.median(c.per_entry for c in costs.values()))


def _pieces(groups: Mapping[str, list[int]], costs: Mapping[str, Cost], fallback: Cost, cap: float) -> list[Piece]:
    """One piece per command; a command costlier than a whole shard splits into the fewest pieces that fit."""
    pieces = []
    for cmd, idx in groups.items():
        c = costs.get(cmd, fallback)
        total = c.baseline + c.per_entry * len(idx)
        k = min(len(idx), max(1, math.ceil(total / cap))) if total > cap else 1
        for part in (idx[i::k] for i in range(k)):
            pieces.append(Piece(part[0], c.baseline + c.per_entry * len(part), part))
    return pieces


def _interleave(pieces: Sequence[Piece]) -> list[int]:
    """Costliest piece first, one entry of each in turn: free mirrors start other baselines instead of waiting on one."""
    queues = [list(p.entries) for p in sorted(pieces, key=lambda p: (-p.cost, p.first))]
    order: list[int] = []
    while queues:
        order.extend(q.pop(0) for q in queues)
        queues = [q for q in queues if q]
    return order


def plan(entries: Sequence[E], costs: Mapping[str, Cost], n: int) -> list[list[E]]:
    """N shards that partition entries, longest piece first onto the lightest shard; the same inputs give the same plan."""
    groups: dict[str, list[int]] = {}
    for i, e in enumerate(entries):
        groups.setdefault(str(e["test"]), []).append(i)
    fallback = default_cost(costs)
    total = sum(costs.get(cmd, fallback).baseline + costs.get(cmd, fallback).per_entry * len(idx)
                for cmd, idx in groups.items())
    cap = max(total / n, 1e-9)
    loads = [0.0] * n
    shards: list[list[Piece]] = [[] for _ in range(n)]
    for piece in sorted(_pieces(groups, costs, fallback, cap), key=lambda p: (-p.cost, p.first)):
        k = loads.index(min(loads))
        loads[k] += piece.cost
        shards[k].append(piece)
    return [[entries[i] for i in _interleave(pieces)] for pieces in shards]


def describe(entries: Sequence[E], costs: Mapping[str, Cost], k: int, n: int, path: str) -> str:
    unknown = {str(e["test"]) for e in entries} - set(costs)
    fallback = default_cost(costs)
    return (f"  shard plan: {k}/{n} from {path}: {len({str(e['test']) for e in entries})} test command(s), "
            f"{len(unknown)} without a recorded cost (assumed {fallback.baseline:.2f}s baseline, "
            f"{fallback.per_entry:.2f}s per entry)")


def read_cost_lines(lines: Iterable[str]) -> dict[str, list[Cost]]:
    """Every cost line in a log, CI prefixes and shard tags included, per command."""
    seen: dict[str, list[Cost]] = {}
    for line in lines:
        m = _COST_LINE.search(line)
        if m:
            n, wall, base = int(m["n"]), float(m["wall"]), float(m["base"])
            seen.setdefault(m["test"], []).append(Cost(base, max(wall - base, 0.0) / max(n, 1)))
    return seen


def table(seen: Mapping[str, Sequence[Cost]], commands: Iterable[str]) -> dict[str, dict[str, float]]:
    """The median observation of each command the manifest still runs, rounded so a refresh diffs readably."""
    return {cmd: {"baseline": round(statistics.median(c.baseline for c in seen[cmd]), 2),
                  "per_entry": round(statistics.median(c.per_entry for c in seen[cmd]), 2)}
            for cmd in sorted(set(commands)) if cmd in seen}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--from-log", action="append", required=True, help="a gate log holding cost lines (repeatable)")
    ap.add_argument("--manifest", required=True, help="keep only the commands this manifest runs")
    ap.add_argument("--write", required=True, help="the cost table to write")
    args = ap.parse_args()
    seen: dict[str, list[Cost]] = {}
    for path in args.from_log:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for cmd, rows in read_cost_lines(fh).items():
                seen.setdefault(cmd, []).extend(rows)
    with open(args.manifest, encoding="utf-8") as fh:
        commands = {str(e["test"]) for e in json.load(fh)}
    rows = table(seen, commands)
    with open(args.write, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(rows, indent=1, sort_keys=True) + "\n")
    print(f"{args.write}: {len(rows)} of {len(commands)} test command(s) costed from {len(args.from_log)} log(s)")
    return 0 if rows else 1


if __name__ == "__main__":
    sys.exit(main())
