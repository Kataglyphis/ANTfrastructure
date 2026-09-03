#!/usr/bin/env python3
"""Fail on NEW `local x="$(cmd)"` — the declaration masks cmd's exit status.

`local`/`export`/`declare`/`readonly` return THEIR OWN status, so `set -e` never
sees the command fail and x silently holds "". shellcheck's SC2155 misses the
`${y:-$(cmd)}` form entirely, and lint-shell.sh gates at -S error, where a
warning cannot fail. See docs/failure-modes.md.

Existing sites are frozen in masked-assignments.allow; this gate only refuses new
ones. Fixing one means deleting its line.
"""
import os
import re
import sys

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


def load_allow():
    if not os.path.exists(ALLOW):
        return set()
    keep = set()
    with open(ALLOW, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#"):
                keep.add(line)
    return keep


def main():
    found = sites()
    allow = load_allow()
    # key on file+variable, NOT the line number: a site must not re-flag because
    # something above it moved.
    keys = {"{}\t{}".format(f, v) for f, _n, v in found}
    print("=== masked declaration gate ===")
    print("  {} `local/export x=$(...)` site(s); {} frozen in {}".format(
        len(found), len(allow), os.path.basename(ALLOW)))

    rc = 0
    new = sorted(k for k in keys if k not in allow)
    if new:
        rc = 1
        print("\nNEW masked declaration(s) — split them:\n", file=sys.stderr)
        for k in new:
            f, v = k.split("\t")
            ln = next((n for ff, n, vv in found if ff == f and vv == v), "?")
            print("  {}:{}  {}".format(f, ln, v), file=sys.stderr)
        print("\n  local x\n  x=\"$(cmd)\" || return 1\n", file=sys.stderr)
    stale = sorted(allow - keys)
    if stale:
        rc = 1
        print("\nSTALE entr(ies) — the site is gone, delete the line:\n", file=sys.stderr)
        for k in stale:
            print("  {}".format(k.replace("\t", "  ")), file=sys.stderr)
    if rc == 0:
        print("OK: no new masked declarations")
    return rc


if __name__ == "__main__":
    sys.exit(main())
