#!/usr/bin/env python3
"""Fail on NEW oversized shell functions.

The repo had no length metric at all: F1/F2 in the backlog were measured by hand,
which is why their tables went stale between rounds and had to be re-measured five
times in one day. Existing functions are frozen in function-size.allow with their
current length, so the gate refuses only growth and new offenders — and shrinking
one below its frozen number fails too, so the baseline cannot rot into cover.

Length is weak evidence on its own. This does not ask anyone to split a function;
it asks that the queue stay honest without a human re-counting.
See docs/code-quality-tooling.md.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ALLOW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "function-size.allow")
LIMIT = int(os.environ.get("FUNCTION_SIZE_LIMIT", "80"))
SCAN = ("linux/scripts", "linux/host-config")
SKIP_DIRS = {".git", "__pycache__", "patches"}
DEF = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{")


def functions():
    """Yield (relpath, name, line_count) for every shell function found."""
    for top in SCAN:
        for base, dirs, files in os.walk(os.path.join(ROOT, top)):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            for fn in sorted(files):
                if not fn.endswith(".sh"):
                    continue
                path = os.path.join(base, fn)
                rel = os.path.relpath(path, ROOT)
                try:
                    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
                except OSError:
                    continue
                for i, line in enumerate(lines):
                    m = DEF.match(line)
                    if not m:
                        continue
                    depth = 0
                    for n, body in enumerate(lines[i:], start=1):
                        depth += body.count("{") - body.count("}")
                        if depth == 0 and n > 1:
                            yield rel, m.group(1), n
                            break


def load_allow():
    frozen = {}
    if not os.path.exists(ALLOW):
        return frozen
    for raw in open(ALLOW, encoding="utf-8"):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 3:
            continue
        frozen[(parts[0], parts[1])] = int(parts[2])
    return frozen


def main():
    frozen = load_allow()
    over = [(f, n, c) for f, n, c in functions() if c > LIMIT]
    rc = 0
    print("=== shell function size gate (limit %d lines) ===" % LIMIT)
    print("  %d function(s) over the limit; %d frozen" % (len(over), len(frozen)))

    seen = set()
    for rel, name, count in sorted(over):
        seen.add((rel, name))
        was = frozen.get((rel, name))
        if was is None:
            rc = 1
            sys.stderr.write(
                "FAIL: %s:%s is %d lines, over the %d-line limit and not frozen -- "
                "split it, or add it to function-size.allow with a reason.\n"
                % (rel, name, count, LIMIT))
        elif count > was:
            rc = 1
            sys.stderr.write(
                "FAIL: %s:%s GREW from %d to %d lines. Frozen numbers may only go "
                "DOWN.\n" % (rel, name, was, count))
        elif count < was:
            rc = 1
            sys.stderr.write(
                "FAIL: %s:%s shrank from %d to %d lines -- update its "
                "function-size.allow entry so the baseline cannot rot.\n"
                % (rel, name, was, count))

    for (rel, name), was in sorted(frozen.items()):
        if (rel, name) not in seen:
            rc = 1
            sys.stderr.write(
                "FAIL: STALE freeze for %s:%s (%d lines) -- it is no longer over the "
                "limit; delete the line.\n" % (rel, name, was))

    if rc == 0:
        print("OK: no new or grown oversized functions")
    return rc


if __name__ == "__main__":
    sys.exit(main())
