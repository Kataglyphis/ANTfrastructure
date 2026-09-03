#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""Shared allowlist contract for the code-quality gates.
Counted metrics use the four-way rule, set metrics the two-way rule.
docs/code-quality-tooling.md#the-allowlist-contract"""

import os
import sys


def load_counts(path):
    """`key | count | reason` rows -> {key-tuple: count}. Keys may carry `|`-separated parts."""
    frozen = {}
    if not os.path.exists(path):
        return frozen
    for raw in open(path, encoding="utf-8"):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 3:
            continue
        frozen[tuple(parts[:-2])] = int(parts[-2])
    return frozen


def check_counts(kind, items, frozen, limit, allow_name, unit="lines"):
    """The four-way contract: a new offender, growth, an unrecorded shrink and a
    stale freeze all fail. `items` = [(key-tuple, count)], `frozen` from load_counts."""
    rc = 0
    over = [(k, n) for k, n in items if n > limit]
    print("  %-9s %d over %d %s; %d frozen" % (kind + ":", len(over), limit, unit, len(frozen)))
    seen = set()
    for key, count in sorted(over):
        seen.add(key)
        label = ":".join(key) if isinstance(key, tuple) else key
        was = frozen.get(key)
        if was is None:
            rc = 1
            sys.stderr.write("FAIL: %s is %d %s, over the %d-%s limit and not "
                             "frozen -- fix it, or add it to %s with a reason.\n"
                             % (label, count, unit, limit, unit.rstrip("s"), allow_name))
        elif count > was:
            rc = 1
            sys.stderr.write("FAIL: %s GREW from %d to %d %s -- update its %s "
                             "entry and say why in the reason column.\n"
                             % (label, was, count, unit, allow_name))
        elif count < was:
            rc = 1
            sys.stderr.write("FAIL: %s shrank from %d to %d %s -- update its %s "
                             "entry so the baseline cannot rot.\n"
                             % (label, was, count, unit, allow_name))
    for key, was in sorted(frozen.items()):
        if key not in seen:
            rc = 1
            label = ":".join(key) if isinstance(key, tuple) else key
            sys.stderr.write("FAIL: STALE freeze for %s (%d %s) -- it is no longer "
                             "over the limit; delete the line.\n" % (label, was, unit))
    return rc


def load_keys(path):
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


def check_keys(keys, frozen, new_head, stale_head, describe=lambda k: k.replace("\t", "  ")):
    """The two-way contract: a key not frozen is NEW, a frozen key not found is STALE.
    Prints each set under its heading via `describe`; returns 1 if either is non-empty."""
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
        for k in stale:
            print("  " + k.replace("\t", "  "), file=sys.stderr)
    return rc
