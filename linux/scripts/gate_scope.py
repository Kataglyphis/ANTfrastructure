#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""The scan-root contract for the ratchet gates. One owner, four rules.

WHY THIS EXISTS. Twelve gates resolved their scan root from ``__file__``, which
in a consumer's ``third_party/ContainerHub`` checkout is the HUB -- so each one
reported green over a tree nobody asked about while ~15,700 lines of consumer
shell went ungraded. Giving them ``--root`` fixed that and immediately produced a
second problem: seven copies of the same twenty lines, because the port was done
per gate. This is those twenty lines, once.

THE FOUR RULES, each of which a copy got wrong somewhere:

1. A ``--root`` must be a git checkout AND its TOPLEVEL. ``git rev-parse``
   succeeds in any subdirectory, so ``--root <repo>/third_party`` passed as a
   valid root and graded a fragment, with relative paths silently anchored one
   level down -- which shifts every allowlist key without saying so.
2. An EMPTY scan is a decision, never a default. ``refuse`` is right where every
   repo must have such files (an empty list means the scope construction broke);
   ``allow`` is right where a repo may legitimately have none, and the caller
   must say which and why.
3. ``git ls-files``, never a walk. A vendored submodule is a gitlink, so
   ls-files cannot descend into another repo, and untracked build output stays
   out. A top-level directory in ``EXCLUDE`` is dropped as well, for subtrees
   vendored as real files rather than as a gitlink.
4. A tracked path that is NOT on disk is reported, not skipped. The walk these
   gates used to do could only yield files that exist; reading the index can
   name files a sparse checkout never materialised, and ``except OSError:
   continue`` turned that into a quiet partial grading.

docs/code-quality-tooling.md#the-scan-root-contract
"""
from __future__ import annotations

import os
import subprocess
import sys

EXCLUDE = ("third_party",)


class ScopeError(Exception):
    """A root or scan set that must stop the gate rather than shrink it."""


def resolve_root(arg, default_root):
    """Absolute, verified scan root. ``None`` means the gate's own repo.

    That ``None`` is load-bearing and every gate must default to it, NOT to
    its own ROOT. Passing ROOT reaches the git-toplevel check below on every
    bare run, so a gate then demands a git checkout merely to grade its own
    tree. Measured 2026-09-10: with default=ROOT the whole set exits 2
    ("is not a git checkout") in a git-less export, and docs/scripts/
    verify_mutations.py cannot prove any of them because its mirror excludes
    .git by design. An explicitly NAMED root still has to be a real
    checkout -- that is the part this check exists for.
    """
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
    """Tracked paths under ``root`` matching ``patterns``, minus ``exclude``.

    Returns repo-relative POSIX paths, sorted. Raises ScopeError if a tracked
    path is missing from the working tree -- see rule 4.
    """
    cmd = ["git", "-C", root, "ls-files", "-z", "--"] + list(patterns)
    out = subprocess.run(cmd, capture_output=True, text=True)
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
