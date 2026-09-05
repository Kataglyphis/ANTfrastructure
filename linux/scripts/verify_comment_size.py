#!/usr/bin/env python3
"""Fail on NEW oversized comment blocks.

Owner directive (AGENTS.md priority 6): two lines at the point of use; anything
longer moves into docs/ and the code keeps a pointer. Existing blocks are frozen
in comment-size.allow so the gate only refuses new ones — shrinking one means
deleting its line. docs/code-quality-tooling.md#comment-size-comment-size
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from quality_allow import check_keys, load_keys  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ALLOW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "comment-size.allow")
LIMIT = int(os.environ.get("COMMENT_SIZE_LIMIT", "10"))
SCAN = ("linux/scripts", "linux/host-config")


def blocks():
    out = []
    for top in SCAN:
        for base, dirs, files in os.walk(os.path.join(ROOT, top)):
            dirs[:] = [d for d in dirs if d not in (".git", "__pycache__")]
            for fn in sorted(files):
                if not fn.endswith(".sh"):
                    continue
                path = os.path.join(base, fn)
                rel = os.path.relpath(path, ROOT)
                try:
                    with open(path, encoding="utf-8", errors="replace") as fh:
                        lines = fh.readlines()
                except OSError:
                    continue
                n = start = 0
                for i, line in enumerate(lines, 1):
                    if line.lstrip().startswith("#"):
                        if n == 0:
                            start = i
                        n += 1
                        continue
                    if n > LIMIT:
                        out.append((rel, start, n))
                    n = 0
                if n > LIMIT:
                    out.append((rel, start, n))
    return out


def main():
    found = blocks()
    allow = load_keys(ALLOW)
    # Key on file + the block's FIRST comment text, not the line number: a block
    # must not re-flag because something above it moved.
    keys = {}
    for rel, start, n in found:
        with open(os.path.join(ROOT, rel), encoding="utf-8", errors="replace") as fh:
                # rstrip AFTER truncating: a key ending in whitespace would not
            # survive the allowlist round-trip.
            first = fh.readlines()[start - 1].strip()[:60].rstrip()
        keys["{}\t{}".format(rel, first)] = (start, n)

    print("=== comment size gate (limit {} lines) ===".format(LIMIT))
    print("  {} block(s) over the limit; {} frozen".format(len(keys), len(allow)))

    def _block(k):
        rel, first = k.split("\t")
        start, n = keys[k]
        return "{}:{}  {} lines".format(rel, start, n)

    rc = check_keys(keys, allow,
                    "NEW oversized comment block(s) — move the detail into docs/ and leave a pointer:",
                    "STALE entr(ies) — that block is gone or now fits, delete the line:", _block)
    if rc == 0:
        print("OK: no new oversized comment blocks")
    return rc


if __name__ == "__main__":
    sys.exit(main())
