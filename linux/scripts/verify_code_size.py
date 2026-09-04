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

This module also owns strip_line/code_lines, the quote-, comment- and heredoc-aware
view of shell source that every extent-based gate imports.
docs/code-quality-tooling.md#what-a-shell-functions-extent-is
"""
import ast
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from quality_allow import check_counts, load_counts  # noqa: E402

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
# DEF_HEAD is the unanchored `name() {` / `function name {` head (shared with
# verify_dead_functions.py); DEF is the column-0 form that opens a measured function.
DEF_HEAD = r"(?:function\s+([A-Za-z_][A-Za-z0-9_]*)(?:\(\))?|([A-Za-z_][A-Za-z0-9_]*)\(\))\s*\{"
DEF = re.compile("^" + DEF_HEAD)


HEREDOC = re.compile(r"(?<!<)<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
QUOTE = {"'": "sq", '"': "dq"}


def _arith_open(line, i):
    """Length of an arithmetic opener at `i`: 3 for `$((`, 2 for a delimited `((`, else 0."""
    if line.startswith("$((", i):
        return 3
    if line.startswith("((", i) and (i == 0 or line[i - 1] in " \t;(|&"):
        return 2
    return 0


def _skip_quoted(line, i, stack, out):
    """Advance one char inside '...' or "..."; a $( inside "..." re-enters code."""
    c, top = line[i], stack[-1]
    if top == "dq" and c == "\\":
        return i + 2
    if c == ("'" if top == "sq" else '"'):
        stack.pop()
        out.append(c)
    elif top == "dq" and line.startswith("$((", i):
        stack.append("arith")
        out.append("$(")
        return i + 3
    elif top == "dq" and line.startswith("$(", i):
        stack.append("sub")
        out.append("$(")
        return i + 2
    return i + 1


def _open_group(line, i, stack, out):
    """Push the group opened at `i` -- $((, (( , $( or ( -- and return the next index,
    or 0 when the char is emitted as ordinary code."""
    n = _arith_open(line, i)
    if n:
        stack.append("arith")
        out.append("$(" if n == 3 else "(")
        return i + n
    if line.startswith("$(", i):
        stack.append("sub")
        out.append("$(")
        return i + 2
    if line[i] == "(":
        stack.append("par")
    return 0


def _close_group(line, i, stack):
    """Pop the group closed by the ')' at `i`; return the next index past a `))`, else 0."""
    top = stack[-1] if stack else None
    if top == "arith" and line.startswith("))", i):
        stack.pop()
        return i + 2
    if top in ("sub", "par"):
        stack.pop()
    return 0


def _code_char(line, i, stack, out, docs):
    """Advance one char of code; -1 at a comment. Quotes and the ( ) groups push onto
    `stack`, a heredoc operator records its terminator in `docs` and leaves the code."""
    c = line[i]
    if c == "#" and (i == 0 or line[i - 1] in " \t;(|&"):
        return -1
    if c == "\\":
        out.append(line[i:i + 2])
        return i + 2
    if c in QUOTE:
        stack.append(QUOTE[c])
    elif c in ("$", "("):
        j = _open_group(line, i, stack, out)
        if j:
            return j
    elif c == ")":
        j = _close_group(line, i, stack)
        if j:
            out.append(c)
            return j
    elif c == "<" and "arith" not in stack and HEREDOC.match(line, i):
        m = HEREDOC.match(line, i)
        docs.append(m.group(2))
        out.append(" ")
        return m.end()
    out.append(c)
    return i + 1


def strip_line(line, stack):
    """Return (code, heredoc_terminators) for one line; `stack` carries quote and
    $( ) context across lines so multi-line strings and substitutions parse right."""
    out, docs, i = [], [], 0
    while 0 <= i < len(line):
        if stack and stack[-1] in ("sq", "dq"):
            i = _skip_quoted(line, i, stack, out)
        else:
            i = _code_char(line, i, stack, out, docs)
    return "".join(out), docs


def code_lines(lines):
    """One stripped line per line in: comment text, quoted text and heredoc bodies gone,
    quote and $( ) state carried across lines."""
    stack, pending, out = [], [], []
    for line in lines:
        if pending:
            out.append("")
            if line.strip() == pending[0]:
                pending.pop(0)
            continue
        code, docs = strip_line(line, stack)
        pending.extend(docs)
        out.append(code)
    return out


def scan(*suffixes):
    """Yield (path, relpath) for every file in SCAN whose name ends in one of `suffixes`."""
    for top in SCAN:
        for base, dirs, files in os.walk(os.path.join(ROOT, top)):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            for fn in sorted(files):
                if fn.endswith(suffixes):
                    path = os.path.join(base, fn)
                    yield path, os.path.relpath(path, ROOT)


def shell_functions(path, rel):
    """Yield (rel, name, start_line, body_lines) for every function in one shell file;
    body_lines runs from the definition line to its closing brace inclusive. Braces are
    counted over code_lines, so a `}` in a comment, a string or a heredoc body neither
    ends a function early nor hides one, and neither does a definition head inside one."""
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        return
    code = code_lines(lines)
    for i, line in enumerate(code):
        m = DEF.match(line)
        if not m:
            continue
        depth = 0
        for n, body in enumerate(code[i:], start=1):
            depth += body.count("{") - body.count("}")
            if depth == 0:
                yield rel, m.group(1) or m.group(2), i + 1, lines[i:i + n]
                break


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
                elif fn.endswith(".sh"):
                    for _rel, name, _start, body in shell_functions(path, rel):
                        yield rel, name, len(body)


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


def main():
    print("=== code size gate (functions > %d, files > %d) ===" % (LIMIT, FILE_LIMIT))
    # A name can be defined more than once in one file (a stub redefined later),
    # and the allow key is (file, name). Take the LONGEST -- the shortest would let
    # a redefinition hide the offender.
    longest: dict = {}
    for f, n, c in functions():
        longest[(f, n)] = max(c, longest.get((f, n), 0))
    rc = check_counts("functions", sorted(longest.items()),
                      load_counts(FN_ALLOW), LIMIT, "function-size.allow")
    rc |= check_counts("files", [((f,), n) for f, n in files()],
                       load_counts(FILE_ALLOW), FILE_LIMIT, "file-size.allow")
    if rc == 0:
        print("OK: no new or grown oversized functions or files")
    return rc


if __name__ == "__main__":
    sys.exit(main())
