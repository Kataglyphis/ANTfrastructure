#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""Shared allowlist contract for the code-quality gates.
Counted metrics use the four-way rule, set metrics the two-way rule.
docs/code-quality-tooling.md#the-allowlist-contract"""

import os
import sys
from collections.abc import Callable, Iterable, Iterator, Mapping
from typing import TypeAlias, TypeVar

FMT = "<key> | ... | <count> | <reason>"
AllowRows: TypeAlias = dict[tuple[str, ...], tuple[int, str]]
CountRows: TypeAlias = dict[tuple[str, ...], int]
Key = TypeVar("Key")


def iter_rows(
    path: str, keys: int | None = None, fmt: str = FMT
) -> Iterator[tuple[tuple[str, ...], int, str, int]]:
    """`key | count | reason` rows -> (key-tuple, count, reason, line number), in file
    order and repeats included. `keys` fixes the number of key columns so a reason may
    carry `|` and `#`; None keeps the count in the second column from the right. A row
    that fits neither is a named gate error."""
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as fh:
        for num, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split("|")]
            at = len(parts) - 2 if keys is None else keys
            if at < 1 or len(parts) < at + 2 or not parts[at].isdigit():
                sys.stderr.write(f"ERROR: {os.path.basename(path)}:{num}: expected '{fmt}'\n")
                raise SystemExit(2)
            yield tuple(parts[:at]), int(parts[at]), " | ".join(parts[at + 1:]), num


def load_rows(path: str, keys: int | None = None, fmt: str = FMT) -> AllowRows:
    """iter_rows as a {key: (count, reason)} table; a repeated key keeps its last row."""
    return {key: (count, reason) for key, count, reason, _num in iter_rows(path, keys, fmt)}


def load_counts(path: str, keys: int | None = None, fmt: str = FMT) -> CountRows:
    """load_rows without the reasons -- what check_counts compares against."""
    return {key: count for key, (count, _reason) in load_rows(path, keys, fmt).items()}


def check_counts(
    kind: str,
    items: Iterable[tuple[Key, int]],
    frozen: Mapping[Key, int],
    limit: int,
    allow_name: str,
    unit: str = "lines",
) -> int:
    """The four-way contract: a new offender, growth, an unrecorded shrink and a
    stale freeze all fail. `items` = [(key-tuple, count)], `frozen` from load_counts."""
    rc = 0
    over = [(k, n) for k, n in items if n > limit]
    print(f"  {kind + ':':<9} {len(over)} over {limit} {unit}; {len(frozen)} frozen")
    seen = set()
    for key, count in sorted(over):
        seen.add(key)
        label = ":".join(key) if isinstance(key, tuple) else key
        was = frozen.get(key)
        if was is None:
            rc = 1
            sys.stderr.write(
                f"FAIL: {label} is {count} {unit}, over the {limit}-{unit.rstrip('s')} limit "
                f"and not frozen -- fix it, or add it to {allow_name} with a reason.\n"
            )
        elif count > was:
            rc = 1
            sys.stderr.write(
                f"FAIL: {label} GREW from {was} to {count} {unit} -- update its {allow_name} "
                "entry and say why in the reason column.\n"
            )
        elif count < was:
            rc = 1
            sys.stderr.write(
                f"FAIL: {label} shrank from {was} to {count} {unit} -- update its {allow_name} "
                "entry so the baseline cannot rot.\n"
            )
    for key, was in sorted(frozen.items()):
        if key not in seen:
            rc = 1
            label = ":".join(key) if isinstance(key, tuple) else key
            sys.stderr.write(f"FAIL: STALE freeze for {label} ({was} {unit}) -- it is no longer "
                             "over the limit; delete the line.\n")
    return rc


def load_keys(path: str) -> set[str]:
    """One frozen key per line (fields tab-separated), `#` comments skipped -> set."""
    keep = set()
    if not os.path.exists(path):
        return keep
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#"):
                keep.add(line)
    return keep


def check_keys(
    keys: Iterable[str],
    frozen: set[str],
    new_head: str,
    stale_head: str,
    describe: Callable[[str], str] = lambda key: key.replace("\t", "  "),
    describe_stale: Callable[[str], str] | None = None,
) -> int:
    """The two-way contract: a key not frozen is NEW, a frozen key not found is STALE.
    Prints each set under its heading; returns 1 if either is non-empty.

    `describe_stale` exists because a stale row does not always mean what its heading
    says: the dead-function gate's unlinked arm can be DISARMED by an unrelated file,
    and "the function is called again" then reads as if the code came back to life.
    A gate that can tell WHY a row went stale says so at the row."""
    rc = 0
    new = sorted(k for k in keys if k not in frozen)
    if new:
        rc = 1
        print("\n" + new_head + "\n", file=sys.stderr)
        for k in new:
            print("  " + describe(k), file=sys.stderr)
    stale = sorted(frozen - set(keys))
    if stale:
        rc = 1
        print("\n" + stale_head + "\n", file=sys.stderr)
        _fmt = describe_stale or (lambda k: k.replace("\t", "  "))
        for k in stale:
            print("  " + _fmt(k), file=sys.stderr)
    return rc
