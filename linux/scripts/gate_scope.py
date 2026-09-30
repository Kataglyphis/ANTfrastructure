#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""The scan-root contract for the ratchet gates. See docs/code-quality-tooling.md#the-scan-root-contract"""
from __future__ import annotations

import os
import subprocess
import sys

EXCLUDE = ("third_party",)


class ScopeError(Exception):
    """A root or scan set that must stop the gate rather than shrink it."""


def resolve_root(arg, default_root):
    """Absolute, verified scan root; ``None`` (never the gate's ROOT) means the gate's own repo."""
    if arg is None:
        return os.path.abspath(default_root)
    root = os.path.abspath(arg)
    if not os.path.isdir(root):
        raise ScopeError("%s is not a directory" % root)
    out = subprocess.run(["git", "-C", root, "rev-parse", "--show-toplevel"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise ScopeError("%s is not a git checkout; --root must be one" % root)
    top = os.path.abspath(out.stdout.strip())
    if top != root:
        raise ScopeError(
            "%s is inside a checkout but is not its root (that is %s).\n"
            "       Grading a fragment anchors every allowlist key one level "
            "down without saying so." % (root, top))
    return root


def is_hub(root, default_root):
    """True when the root is the gate's own repo, i.e. nothing may change."""
    return os.path.abspath(root) == os.path.abspath(default_root)


def tracked(root, patterns, exclude=EXCLUDE):
    """Sorted repo-relative paths tracked under ``root``; ScopeError if one is missing on disk."""
    cmd = ["git", "-C", root, "ls-files", "-z", "--"] + list(patterns)
    # Pinned: a cp1252 host's default codec raises on a non-ASCII tracked path.
    out = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")
    if out.returncode != 0:
        raise ScopeError("%s is not a git checkout; --root must be one" % root)
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
        raise ScopeError(
            "%d tracked file(s) are in the index but not on disk, so this gate "
            "would grade a partial tree:\n       %s\n"
            "       A sparse or partial checkout cannot be graded; check out the "
            "whole tree." % (len(missing), "\n       ".join(sorted(missing)[:10])))
    return sorted(rels)


def assert_non_empty(rels, root, patterns, on_empty, label):
    """Apply rule 2. Returns True when the gate should carry on."""
    if rels:
        return True
    what = " ".join(patterns)
    if on_empty == "allow":
        print("%s: no tracked %s outside %s under %s - nothing to grade."
              % (label, what, "/".join(EXCLUDE), root))
        return False
    raise ScopeError(
        "no tracked %s outside %s under %s.\n"
        "       Refusing to report green over nothing: an empty list here means "
        "the scope construction broke, not that the repo is clean." % (what, "/".join(EXCLUDE), root))


def die(exc):
    """Uniform exit for a ScopeError: named, on stderr, rc 2."""
    sys.stderr.write("ERROR: %s\n" % exc)
    return 2
