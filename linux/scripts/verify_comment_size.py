#!/usr/bin/env python3
"""Fail on NEW oversized comment blocks.

Owner directive (AGENTS.md priority 6): two lines at the point of use; anything
longer moves into docs/ and the code keeps a pointer. Existing blocks are frozen
in comment-size.allow so the gate only refuses new ones — shrinking one means
deleting its line. docs/code-quality-tooling.md#comment-size-comment-size

GRADING A CONSUMER. `--root` follows docs/scripts/verify_mutations.py, which
takes the same flag for the same job; the freeze-file flag beside it is this
gate's own (verify_mutations names its state file --manifest). Both exist for the
reason the lint gates take a root: a submodule checkout puts this script INSIDE the consumer,
where a root derived from __file__ resolves to ContainerHub and the gate grades
the wrong tree while reporting green over one nobody looked at.

Under the hub's own root the scan set is the historical SCAN tuple, so the hub's
own verdict is unchanged. Under any other root it is every TRACKED *.sh minus the
excluded top-level directories — the same rule run-lint-gates.sh uses, so a
consumer needs no per-repo configuration and a vendored subtree cannot creep in.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from quality_allow import check_keys, load_keys  # noqa: E402
import gate_scope  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ALLOW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "comment-size.allow")
LIMIT = int(os.environ.get("COMMENT_SIZE_LIMIT", "10"))
SCAN = ("linux/scripts", "linux/host-config", "docs/scripts", "linux/llm-stack")
# verify_code_size.SCAN, minus its SKIP_DIRS: patches/ holds one real script whose
# header this gate has always covered. Shell-only, so docs/scripts contributes none.


def _walk_scan(root, tops):
    """Every *.sh under the named top-level directories."""
    for top in tops:
        for base, dirs, files in os.walk(os.path.join(root, top)):
            dirs[:] = [d for d in dirs if d not in (".git", "__pycache__")]
            for fn in sorted(files):
                if fn.endswith(".sh"):
                    yield os.path.relpath(os.path.join(base, fn), root)


def scan_paths(root, scan):
    if scan:
        return sorted(_walk_scan(root, scan))
    if gate_scope.is_hub(root, ROOT):
        return sorted(_walk_scan(root, SCAN))
    return gate_scope.tracked(root, ['*.sh'])


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

    try:

        # resolve_root, not abspath: a SUBDIRECTORY of a checkout passes

        # `git rev-parse`, and grading a fragment anchors every allowlist

        # key one level down without saying so.

        root = gate_scope.resolve_root(args.root, ROOT)

    except gate_scope.ScopeError as exc:

        return gate_scope.die(exc)
    # A consumer's freeze belongs to the consumer: keeping it beside this script
    # would put every repo's ratchet inside the hub, where no consumer can see it
    # in its own diff.
    allow = args.allow or (ALLOW if root == os.path.abspath(ROOT)
                           else os.path.join(root, "comment-size.allow"))

    try:

        found = blocks(root, scan_paths(root, args.scan))

    except gate_scope.ScopeError as exc:

        return gate_scope.die(exc)
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
