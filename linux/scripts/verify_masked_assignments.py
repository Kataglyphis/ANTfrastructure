#!/usr/bin/env python3
"""Fail on NEW `local x="$(cmd)"` — the declaration masks cmd's exit status.

`local`/`export`/`declare`/`readonly` return THEIR OWN status, so `set -e` never
sees the command fail and x silently holds "". shellcheck's SC2155 misses the
`${y:-$(cmd)}` form entirely, and lint-shell.sh gates at -S error, where a
warning cannot fail.
docs/failure-modes.md#a-declaration-that-masks-its-commands-exit-status

Existing sites are frozen in masked-assignments.allow; this gate only refuses new
ones. Fixing one means deleting its line.

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
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from quality_allow import check_keys, load_keys  # noqa: E402
import gate_scope  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ALLOW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "masked-assignments.allow")
DECL = re.compile(r"^\s*(?:local|export|declare|readonly)\s+(?:-\w+\s+)*([A-Za-z_][A-Za-z0-9_]*)=")
SUBST = re.compile(r"\$\(|`")
SCAN = ("linux",)


def _walk_scan(root, tops):
    """Every *.sh under the named top-level directories."""
    for top in tops:
        for base, dirs, files in os.walk(os.path.join(root, top)):
            dirs[:] = [d for d in dirs if d not in (".git", "node_modules", "__pycache__")]
            for fn in files:
                if fn.endswith(".sh"):
                    yield os.path.relpath(os.path.join(base, fn), root)


def scan_paths(root):
    if gate_scope.is_hub(root, ROOT):
        return sorted(_walk_scan(root, SCAN))
    return gate_scope.tracked(root, ['*.sh'])


def sites(root, rels):
    out = []
    for rel in rels:
        path = os.path.join(root, rel)
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                lines = fh.readlines()
        except OSError:
            continue
        for n, line in enumerate(lines, 1):
            code = line.split("#", 1)[0]
            m = DECL.match(code)
            if m and SUBST.search(code):
                out.append((rel, n, m.group(1)))
    return sorted(out)


def main():
    ap = argparse.ArgumentParser(description="Fail on new masked declarations.")
    ap.add_argument("--root", default=ROOT,
                    help="the tree to grade (default: this repo)")
    ap.add_argument("--allow", default=None,
                    help="the freeze file (default: masked-assignments.allow beside "
                         "this script for the hub, <root>/masked-assignments.allow "
                         "otherwise)")
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
    allow_path = args.allow or (ALLOW if root == os.path.abspath(ROOT)
                                else os.path.join(root, "masked-assignments.allow"))

    try:

        found = sites(root, scan_paths(root))

    except gate_scope.ScopeError as exc:

        return gate_scope.die(exc)
    allow = load_keys(allow_path)
    # key on file+variable, NOT the line number: a site must not re-flag because
    # something above it moved.
    keys = {"{}\t{}".format(f, v) for f, _n, v in found}
    print("=== masked declaration gate ===")
    if root != os.path.abspath(ROOT):
        print("  root: {}".format(root))
        print("  allow: {}".format(allow_path))
    print("  {} `local/export x=$(...)` site(s); {} frozen in {}".format(
        len(found), len(allow), os.path.basename(allow_path)))

    def _site(k):
        f, v = k.split("\t")
        ln = next((n for ff, n, vv in found if ff == f and vv == v), "?")
        return "{}:{}  {}".format(f, ln, v)

    rc = check_keys(keys, allow,
                    'NEW masked declaration(s) — split them:\n\n  local x\n  x="$(cmd)" || return 1',
                    "STALE entr(ies) — the site is gone, delete the line:", _site)
    if rc == 0:
        print("OK: no new masked declarations")
    return rc


if __name__ == "__main__":
    sys.exit(main())
