#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""Shared allowlist contract for the code-quality gates.
Counted metrics use the four-way rule, set metrics the two-way rule.
docs/code-quality-tooling.md#the-allowlist-contract"""

import os
import sys


FMT = "<key> | ... | <count> | <reason>"


def iter_rows(path, keys=None, fmt=FMT):
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
                sys.stderr.write("ERROR: %s:%d: expected '%s'\n"
                                 % (os.path.basename(path), num, fmt))
                raise SystemExit(2)
            yield tuple(parts[:at]), int(parts[at]), " | ".join(parts[at + 1:]), num


def load_rows(path, keys=None, fmt=FMT):
    """iter_rows as a {key: (count, reason)} table; a repeated key keeps its last row."""
    return {key: (count, reason) for key, count, reason, _num in iter_rows(path, keys, fmt)}


def load_counts(path, keys=None, fmt=FMT):
    """load_rows without the reasons -- what check_counts compares against."""
    return {key: count for key, (count, _reason) in load_rows(path, keys, fmt).items()}


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
