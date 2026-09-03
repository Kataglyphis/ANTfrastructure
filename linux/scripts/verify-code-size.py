#!/usr/bin/env python3
"""Keep the size of shell functions and files honest.

The number in the allow file must match reality in BOTH directions, so a size can
never drift unnoticed: growing one is allowed, but only as a deliberate, reviewable
edit that shows up in the diff next to a reason. Blocking growth outright would
just push a needed addition into the wrong file.

The repo had no length metric at all: F1/F2 in the backlog were measured by hand,
which is why their tables went stale between rounds and had to be re-measured five
times in one day. Existing offenders are frozen in function-size.allow and
file-size.allow with their current length, so the gate refuses only growth and new offenders — and shrinking
one below its frozen number fails too, so the baseline cannot rot into cover.

Length is weak evidence on its own. This does not ask anyone to split a function;
it asks that the queue stay honest without a human re-counting.
See docs/code-quality-tooling.md.
"""
import ast
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HERE = os.path.dirname(os.path.abspath(__file__))
FN_ALLOW = os.path.join(HERE, "function-size.allow")
FILE_ALLOW = os.path.join(HERE, "file-size.allow")
LIMIT = int(os.environ.get("FUNCTION_SIZE_LIMIT", "80"))
FILE_LIMIT = int(os.environ.get("FILE_SIZE_LIMIT", "800"))
SCAN = ("linux/scripts", "linux/host-config", "docs/scripts")
# Dockerfiles sit at the top of linux/ and have no function structure, so they
# are size-checked as files only. windows/ is out of scope for this repo lane.
FLAT_SCAN = ("linux",)
SKIP_DIRS = {".git", "__pycache__", "patches"}
def _is_subject(fn):
    return fn.endswith(".sh") or fn.endswith(".py") or fn.startswith("Dockerfile")
DEF = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{")


def functions():
    """Yield (relpath, name, line_count) for every shell function found."""
    for top in SCAN:
        for base, dirs, files in os.walk(os.path.join(ROOT, top)):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            for fn in sorted(files):
                path = os.path.join(base, fn)
                rel = os.path.relpath(path, ROOT)
                if fn.endswith(".py"):
                    for item in _py_functions(path, rel):
                        yield item
                    continue
                if not fn.endswith(".sh"):
                    continue
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


def files():
    """Yield (relpath, line_count) for every shell file scanned."""
    for top in SCAN:
        for base, dirs, fs in os.walk(os.path.join(ROOT, top)):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            for fn in sorted(fs):
                if not _is_subject(fn):
                    continue
                path = os.path.join(base, fn)
                try:
                    n = sum(1 for _ in open(path, encoding="utf-8", errors="replace"))
                except OSError:
                    continue
                yield os.path.relpath(path, ROOT), n
    for top in FLAT_SCAN:
        d = os.path.join(ROOT, top)
        for fn in sorted(os.listdir(d) if os.path.isdir(d) else []):
            if not fn.startswith("Dockerfile"):
                continue
            path = os.path.join(d, fn)
            if not os.path.isfile(path):
                continue
            try:
                n = sum(1 for _ in open(path, encoding="utf-8", errors="replace"))
            except OSError:
                continue
            yield os.path.relpath(path, ROOT), n


def _py_functions(path, rel):
    """Yield (rel, qualified_name, line_count) for every def/async def."""
    try:
        tree = ast.parse(open(path, encoding="utf-8", errors="replace").read())
    except (OSError, SyntaxError):
        return
    stack = []

    def walk(node, prefix):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, ast.ClassDef):
                walk(child, prefix + child.name + ".")
            elif isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                end = getattr(child, "end_lineno", None)
                if end:
                    stack.append((rel, prefix + child.name, end - child.lineno + 1))
                walk(child, prefix + child.name + ".")
    walk(tree, "")
    for item in stack:
        yield item


def load_allow(path):
    frozen = {}
    if not os.path.exists(path):
        return frozen
    for raw in open(path, encoding="utf-8"):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 3:
            continue
        frozen[tuple(parts[:-2])] = int(parts[-2])
    return frozen


def _check(kind, items, frozen, limit, allow_name):
    """The four-way contract, shared by both metrics: a new offender, growth, an
    unrecorded shrink and a stale freeze all fail."""
    rc = 0
    over = [(k, n) for k, n in items if n > limit]
    print("  %-9s %d over %d lines; %d frozen" % (kind + ":", len(over), limit, len(frozen)))
    seen = set()
    for key, count in sorted(over):
        seen.add(key)
        label = ":".join(key) if isinstance(key, tuple) else key
        was = frozen.get(key)
        if was is None:
            rc = 1
            sys.stderr.write("FAIL: %s is %d lines, over the %d-line limit and not "
                             "frozen -- split it, or add it to %s with a reason.\n"
                             % (label, count, limit, allow_name))
        elif count > was:
            rc = 1
            sys.stderr.write("FAIL: %s GREW from %d to %d lines -- update its %s "
                             "entry and say why in the reason column.\n"
                             % (label, was, count, allow_name))
        elif count < was:
            rc = 1
            sys.stderr.write("FAIL: %s shrank from %d to %d lines -- update its %s "
                             "entry so the baseline cannot rot.\n"
                             % (label, was, count, allow_name))
    for key, was in sorted(frozen.items()):
        if key not in seen:
            rc = 1
            label = ":".join(key) if isinstance(key, tuple) else key
            sys.stderr.write("FAIL: STALE freeze for %s (%d lines) -- it is no longer "
                             "over the limit; delete the line.\n" % (label, was))
    return rc


def main():
    print("=== code size gate (functions > %d, files > %d) ===" % (LIMIT, FILE_LIMIT))
    rc = _check("functions", [((f, n), c) for f, n, c in functions()],
                load_allow(FN_ALLOW), LIMIT, "function-size.allow")
    rc |= _check("files", [((f,), n) for f, n in files()],
                 load_allow(FILE_ALLOW), FILE_LIMIT, "file-size.allow")
    if rc == 0:
        print("OK: no new or grown oversized functions or files")
    return rc


if __name__ == "__main__":
    sys.exit(main())
