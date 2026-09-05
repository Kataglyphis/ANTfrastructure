#!/usr/bin/env python3
"""Fail on NEW `local x="$(cmd)"` — the declaration masks cmd's exit status.

`local`/`export`/`declare`/`readonly` return THEIR OWN status, so `set -e` never
sees the command fail and x silently holds "". shellcheck's SC2155 misses the
`${y:-$(cmd)}` form entirely, and lint-shell.sh gates at -S error, where a
warning cannot fail.
docs/failure-modes.md#a-declaration-that-masks-its-commands-exit-status

Existing sites are frozen in masked-assignments.allow; this gate only refuses new
ones. Fixing one means deleting its line.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from quality_allow import check_keys, load_keys  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ALLOW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "masked-assignments.allow")
DECL = re.compile(r"^\s*(?:local|export|declare|readonly)\s+(?:-\w+\s+)*([A-Za-z_][A-Za-z0-9_]*)=")
SUBST = re.compile(r"\$\(|`")


def sites():
    out = []
    for base, dirs, files in os.walk(os.path.join(ROOT, "linux")):
        dirs[:] = [d for d in dirs if d not in (".git", "node_modules", "__pycache__")]
        for fn in files:
            if not fn.endswith(".sh"):
                continue
            path = os.path.join(base, fn)
            rel = os.path.relpath(path, ROOT)
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
    found = sites()
    allow = load_keys(ALLOW)
    # key on file+variable, NOT the line number: a site must not re-flag because
    # something above it moved.
    keys = {"{}\t{}".format(f, v) for f, _n, v in found}
    print("=== masked declaration gate ===")
    print("  {} `local/export x=$(...)` site(s); {} frozen in {}".format(
        len(found), len(allow), os.path.basename(ALLOW)))

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
