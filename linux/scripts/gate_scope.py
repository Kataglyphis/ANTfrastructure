#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""The scan-root contract for the ratchet gates. See docs/code-quality-tooling.md#the-scan-root-contract"""
from __future__ import annotations

import os
import subprocess
import sys
from collections.abc import Sequence

EXCLUDE = ("third_party",)


class ScopeError(Exception):
    """A root or scan set that must stop the gate rather than shrink it."""


def resolve_root(
    arg: str | os.PathLike[str] | None, default_root: str | os.PathLike[str]
) -> str:
    """Absolute, verified scan root; ``None`` (never the gate's ROOT) means the gate's own repo."""
    if arg is None:
        return os.path.abspath(default_root)
    root = os.path.abspath(arg)
    if not os.path.isdir(root):
        raise ScopeError(f"{root} is not a directory")
    out = subprocess.run(["git", "-C", root, "rev-parse", "--show-toplevel"],
                         capture_output=True, check=False, text=True)
    if out.returncode != 0:
        raise ScopeError(f"{root} is not a git checkout; --root must be one")
    top = os.path.abspath(out.stdout.strip())
    if top != root:
        raise ScopeError(
            f"{root} is inside a checkout but is not its root (that is {top}).\n"
            "       Grading a fragment anchors every allowlist key one level "
            "down without saying so.")
    return root


def is_hub(root: str | os.PathLike[str], default_root: str | os.PathLike[str]) -> bool:
    """True when the root is the gate's own repo, i.e. nothing may change."""
    return os.path.abspath(root) == os.path.abspath(default_root)


def tracked(
    root: str | os.PathLike[str], patterns: Sequence[str], exclude: tuple[str, ...] = EXCLUDE
) -> list[str]:
    """Sorted repo-relative paths tracked under ``root``; ScopeError if one is missing on disk."""
    cmd = ["git", "-C", root, "ls-files", "-z", "--"] + list(patterns)
    # Pinned: a cp1252 host's default codec raises on a non-ASCII tracked path.
    out = subprocess.run(cmd, capture_output=True, check=False, text=True, encoding="utf-8")
    if out.returncode != 0:
        raise ScopeError(f"{root} is not a git checkout; --root must be one")
    rels, missing = [], []
    for rel in out.stdout.split("\0"):
        if not rel:
            continue
        head = rel.split("/", 1)[0]
        if head in exclude and rel != head:
            continue
        if not os.path.exists(os.path.join(root, rel)):
            missing.append(rel)
            continue
        rels.append(rel)
    if missing:
        listed = "\n       ".join(sorted(missing)[:10])
        raise ScopeError(
            f"{len(missing)} tracked file(s) are in the index but not on disk, so this gate "
            f"would grade a partial tree:\n       {listed}\n"
            "       A sparse or partial checkout cannot be graded; check out the "
            "whole tree.")
    return sorted(rels)


def assert_non_empty(
    rels: Sequence[str | os.PathLike[str]],
    root: str | os.PathLike[str],
    patterns: Sequence[str],
    on_empty: str,
    label: str,
) -> bool:
    """Apply rule 2. Returns True when the gate should carry on."""
    if rels:
        return True
    what = " ".join(patterns)
    if on_empty == "allow":
        print(f"{label}: no tracked {what} outside {'/'.join(EXCLUDE)} under {root} - nothing to grade.")
        return False
    raise ScopeError(
        f"no tracked {what} outside {'/'.join(EXCLUDE)} under {root}.\n"
        "       Refusing to report green over nothing: an empty list here means "
        "the scope construction broke, not that the repo is clean.")


def die(exc: ScopeError) -> int:
    """Uniform exit for a ScopeError: named, on stderr, rc 2."""
    sys.stderr.write(f"ERROR: {exc}\n")
    return 2
