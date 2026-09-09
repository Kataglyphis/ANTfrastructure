#!/usr/bin/env python3
"""Fail on NEW oversized comment blocks.

Owner directive (AGENTS.md priority 6): two lines at the point of use; anything
longer moves into docs/ and the code keeps a pointer. Existing blocks are frozen
in comment-size.allow so the gate only refuses new ones — shrinking one means
deleting its line. docs/code-quality-tooling.md#comment-size-comment-size

GRADING A CONSUMER. `--root` and `--allow` are the same contract
docs/scripts/verify_mutations.py already documents, and for the same reason the
lint gates take one: a submodule checkout puts this script INSIDE the consumer,
where a root derived from __file__ resolves to ContainerHub and the gate grades
the wrong tree while reporting green over one nobody looked at.

Under the hub's own root the scan set is the historical SCAN tuple, so the hub's
own verdict is unchanged. Under any other root it is every TRACKED *.sh minus the
excluded top-level directories — the same rule run-lint-gates.sh uses, so a
consumer needs no per-repo configuration and a vendored subtree cannot creep in.
"""
import argparse
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from quality_allow import check_keys, load_keys  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ALLOW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "comment-size.allow")
LIMIT = int(os.environ.get("COMMENT_SIZE_LIMIT", "10"))
SCAN = ("linux/scripts", "linux/host-config")
EXCLUDE = ("third_party",)


def _walk_scan(root, tops):
    """Every *.sh under the named top-level directories."""
    for top in tops:
        for base, dirs, files in os.walk(os.path.join(root, top)):
            dirs[:] = [d for d in dirs if d not in (".git", "__pycache__")]
            for fn in sorted(files):
                if fn.endswith(".sh"):
                    yield os.path.relpath(os.path.join(base, fn), root)


def _tracked_shell(root):
    """Every tracked *.sh outside the excluded tops.

    `git ls-files`, not a walk: a vendored submodule is a GITLINK, so the scope
    cannot swallow another repo's scripts, and build output cannot get in.
    """
    out = subprocess.run(["git", "-C", root, "ls-files", "-z", "--", "*.sh"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        sys.stderr.write("ERROR: %s is not a git checkout; --root must be one\n" % root)
        raise SystemExit(2)
    for rel in out.stdout.split("\0"):
        if not rel:
            continue
        head = rel.split("/", 1)[0]
        if head in EXCLUDE and rel != head:
            continue
        yield rel


def scan_paths(root, scan):
    if scan:
        return sorted(_walk_scan(root, scan))
    if os.path.abspath(root) == os.path.abspath(ROOT):
        return sorted(_walk_scan(root, SCAN))
    return sorted(_tracked_shell(root))


def blocks(root, rels):
    out = []
    for rel in rels:
        path = os.path.join(root, rel)
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
    ap = argparse.ArgumentParser(description="Fail on new oversized comment blocks.")
    ap.add_argument("--root", default=ROOT,
                    help="the tree to grade (default: this repo)")
    ap.add_argument("--allow", default=None,
                    help="the freeze file (default: comment-size.allow beside this "
                         "script for the hub, <root>/comment-size.allow otherwise)")
    ap.add_argument("--scan", action="append",
                    help="restrict to this top-level directory (repeatable)")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    # A consumer's freeze belongs to the consumer: keeping it beside this script
    # would put every repo's ratchet inside the hub, where no consumer can see it
    # in its own diff.
    allow = args.allow or (ALLOW if root == os.path.abspath(ROOT)
                           else os.path.join(root, "comment-size.allow"))

    found = blocks(root, scan_paths(root, args.scan))
    frozen = load_keys(allow)
    # Key on file + the block's FIRST comment text, not the line number: a block
    # must not re-flag because something above it moved.
    keys = {}
    for rel, start, n in found:
        with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as fh:
                # rstrip AFTER truncating: a key ending in whitespace would not
            # survive the allowlist round-trip.
            first = fh.readlines()[start - 1].strip()[:60].rstrip()
        keys["{}\t{}".format(rel, first)] = (start, n)

    print("=== comment size gate (limit {} lines) ===".format(LIMIT))
    if root != os.path.abspath(ROOT):
        print("  root: {}".format(root))
        print("  allow: {}".format(allow))
    print("  {} block(s) over the limit; {} frozen".format(len(keys), len(frozen)))

    def _block(k):
        rel, first = k.split("\t")
        start, n = keys[k]
        return "{}:{}  {} lines".format(rel, start, n)

    rc = check_keys(keys, frozen,
                    "NEW oversized comment block(s) — move the detail into docs/ and leave a pointer:",
                    "STALE entr(ies) — that block is gone or now fits, delete the line:", _block)
    if rc == 0:
        print("OK: no new oversized comment blocks")
    return rc


if __name__ == "__main__":
    sys.exit(main())
