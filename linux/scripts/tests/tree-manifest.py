#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""List a directory tree for comparing two builds of it, or compare two such lists.

Usage: tree-manifest.py DIR > LIST | tree-manifest.py --diff LIST_A LIST_B; see docs/riscv64-cross-test-lanes.md#the-sysroot-from-the-registry-skopeo
"""
from __future__ import annotations

import hashlib
import json
import os
import stat
import sys

FIELDS = ("type", "mode", "size", "nlink", "mtime", "content")
# The build stamp names the mode that wrote the tree, so it always differs.
SKIP = {".riscv64-sysroot"}
EXAMPLES = 15


def describe(path: str) -> list:
    """[type, mode, size, nlink, mtime, content]; directory and symlink times are not compared."""
    st = os.lstat(path)
    mode = "%o" % stat.S_IMODE(st.st_mode)
    if stat.S_ISLNK(st.st_mode):
        return ["l", mode, 0, 1, 0, os.readlink(path)]
    if stat.S_ISDIR(st.st_mode):
        return ["d", mode, 0, 1, 0, ""]
    if not stat.S_ISREG(st.st_mode):
        return ["o", mode, 0, 1, 0, ""]
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                digest.update(chunk)
        content = digest.hexdigest()
    except PermissionError:
        content = "unreadable"
    return ["f", mode, st.st_size, st.st_nlink, int(st.st_mtime), content]


def write_list(root: str) -> int:
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(dirnames + filenames):
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root)
            if rel not in SKIP:
                print(json.dumps([rel] + describe(path)))
    return 0


def read_list(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        return {row[0]: row[1:] for row in map(json.loads, fh)}


def diff_lists(a_path: str, b_path: str) -> int:
    a, b = read_list(a_path), read_list(b_path)
    findings: dict[str, list[str]] = {}
    for rel in sorted(set(a) | set(b)):
        if rel not in b or rel not in a:
            findings.setdefault("only in %s" % (a_path if rel in a else b_path), []).append(rel)
            continue
        for i, field in enumerate(FIELDS):
            if a[rel][i] != b[rel][i]:
                findings.setdefault("%s differs" % field, []).append("%s: %s != %s" % (rel, a[rel][i], b[rel][i]))
    print("%d entries vs %d entries" % (len(a), len(b)))
    for kind, rows in findings.items():
        print("%s: %d" % (kind, len(rows)))
        for row in rows[:EXAMPLES]:
            print("  " + row)
    if not findings:
        print("identical: paths, types, modes, sizes, link counts, file mtimes, link targets and content")
    return 1 if findings else 0


def main(argv: list[str]) -> int:
    if len(argv) == 2 and os.path.isdir(argv[1]):
        return write_list(argv[1])
    if len(argv) == 4 and argv[1] == "--diff":
        return diff_lists(argv[2], argv[3])
    sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
