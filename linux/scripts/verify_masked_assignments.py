#!/usr/bin/env python3
"""Fail on NEW `local x="$(cmd)"`, whose declaration masks cmd's exit status (masked-assignments.allow).

docs/failure-modes.md#a-declaration-that-masks-its-commands-exit-status
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
                    # Posix-spelled keys, or Windows backslashes break every frozen row.
                    yield os.path.relpath(os.path.join(base, fn), root).replace(os.sep, "/")


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
    ap.add_argument("--root", default=None,
                    help="the tree to grade (default: this repo)")
    ap.add_argument("--allow", default=None,
                    help="the freeze file (default: masked-assignments.allow beside "
                         "this script for the hub, <root>/masked-assignments.allow "
                         "otherwise)")
    args = ap.parse_args()

    try:

        # resolve_root, not abspath: a subdirectory root would silently shift every allowlist key.

        root = gate_scope.resolve_root(args.root, ROOT)

    except gate_scope.ScopeError as exc:

        return gate_scope.die(exc)
    # A consumer's freeze lives in the consumer, where its own diff shows it.
    allow_path = args.allow or (ALLOW if root == os.path.abspath(ROOT)
                                else os.path.join(root, "masked-assignments.allow"))

    try:

        found = sites(root, scan_paths(root))

    except gate_scope.ScopeError as exc:

        return gate_scope.die(exc)
    allow = load_keys(allow_path)
    # Keyed on file and variable, not line, so moves above a site do not re-flag it.
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
