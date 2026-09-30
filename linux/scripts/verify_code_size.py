#!/usr/bin/env python3
"""Function and file sizes must match their frozen numbers in both directions; also owns the shell code_lines view.

docs/code-quality-tooling.md#what-a-shell-functions-extent-is
"""
import argparse
import ast
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from quality_allow import check_counts, load_counts  # noqa: E402

import gate_scope  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HERE = os.path.dirname(os.path.abspath(__file__))
FN_ALLOW = os.path.join(HERE, "function-size.allow")
FILE_ALLOW = os.path.join(HERE, "file-size.allow")
FN_FMT = "<path> | <function> | <lines> | <reason>"
FILE_FMT = "<path> | <lines> | <reason>"
LIMIT = int(os.environ.get("FUNCTION_SIZE_LIMIT", "80"))
FILE_LIMIT = int(os.environ.get("FILE_SIZE_LIMIT", "800"))
# SCAN is walked recursively; FLAT_SCAN only adds the top-level Dockerfiles, sized as files.
SCAN = ("linux/scripts", "linux/host-config", "docs/scripts", "linux/llm-stack")
FLAT_SCAN = ("linux",)
# Directories never walked.
SKIP_DIRS = {".git", "__pycache__", "patches"}
def _is_subject(fn):
    return fn.endswith(".sh") or fn.endswith(".py") or fn.startswith("Dockerfile")
# DEF_HEAD is unanchored (verify_dead_functions.py shares it); DEF is the column-0 form.
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
    """Push the $((, ((, $( or ( group opened at `i`; the next index, or 0 when the char is plain code."""
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
    """Advance one char of code, -1 at a comment; a heredoc operator records its terminator in `docs`."""
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
    """(code, heredoc_terminators) for one line; `stack` carries quote and $( ) context across lines."""
    out, docs, i = [], [], 0
    while 0 <= i < len(line):
        if stack and stack[-1] in ("sq", "dq"):
            i = _skip_quoted(line, i, stack, out)
        else:
            i = _code_char(line, i, stack, out, docs)
    return "".join(out), docs


def code_lines(lines):
    """One line out per line in, with comments, quoted text and heredoc bodies blanked."""
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


def _rel(path, root):
    """Posix-spelled relpath, since allowlist keys never carry Windows backslashes."""
    return os.path.relpath(path, root).replace(os.sep, "/")


def _walk_scan(root, tops, match):
    """Yield (path, relpath) for every file under `tops` whose name `match` accepts."""
    for top in tops:
        for base, dirs, names in os.walk(os.path.join(root, top)):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            for fn in sorted(names):
                if match(fn):
                    path = os.path.join(base, fn)
                    yield path, _rel(path, root)


def _flat_scan(root, tops, match):
    """Yield (path, relpath) for the files sitting directly IN `tops` -- no recursion."""
    for top in tops:
        d = os.path.join(root, top)
        for fn in sorted(os.listdir(d) if os.path.isdir(d) else []):
            path = os.path.join(d, fn)
            if match(fn) and os.path.isfile(path):
                yield path, _rel(path, root)


def _tracked_scan(root, match):
    """(path, rel) for every tracked file gate_scope admits whose basename `match` accepts."""
    for rel in gate_scope.tracked(root, ["*"]):
        if match(os.path.basename(rel)):
            yield os.path.join(root, rel), rel

def _under(rel, tops):
    """True when `rel` is one of `tops` or lives inside one."""
    return any(rel == t or rel.startswith(t.rstrip("/") + "/") for t in tops)


def subjects(root, match, tops=None):
    """(path, relpath) scan set: SCAN walked under the hub, the tracked set elsewhere, which `tops` only filters."""
    root = os.path.abspath(root or ROOT)
    if root == os.path.abspath(ROOT):
        return _walk_scan(root, tops or SCAN, match)
    return ((path, rel) for path, rel in _tracked_scan(root, match)
            if not tops or _under(rel, tops))


def scan(*suffixes, root=None, tops=None):
    """(path, relpath) per scan-set file ending in `suffixes`; with no root, sibling gates get the hub corpus."""
    return subjects(root, lambda fn: fn.endswith(suffixes), tops)


def shell_functions(path, rel):
    """(rel, name, start_line, body_lines) per shell function, braces counted over code_lines only."""
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


def functions(root=None, tops=None):
    """Yield (relpath, name, line_count) for every shell or Python function found."""
    for path, rel in subjects(root, lambda fn: fn.endswith((".py", ".sh")), tops):
        if rel.endswith(".py"):
            for item in _py_functions(path, rel):
                yield item
        else:
            for _rel, name, _start, body in shell_functions(path, rel):
                yield rel, name, len(body)


def _line_count(path):
    """The file's line count, or None when it cannot be read."""
    try:
        return sum(1 for _ in open(path, encoding="utf-8", errors="replace"))
    except OSError:
        return None


def files(root=None, tops=None):
    """Yield (relpath, line_count) for every file graded as a whole."""
    root = os.path.abspath(root or ROOT)
    for path, rel in subjects(root, _is_subject, tops):
        n = _line_count(path)
        if n is not None:
            yield rel, n
    # Only the hub needs the flat pass: its Dockerfiles sit above every recursive scan root.
    if tops or root != os.path.abspath(ROOT):
        return
    for path, rel in _flat_scan(root, FLAT_SCAN, lambda fn: fn.startswith("Dockerfile")):
        n = _line_count(path)
        if n is not None:
            yield rel, n


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
    ap = argparse.ArgumentParser(description="Keep function and file sizes honest.")
    ap.add_argument("--root", default=None,
                    help="the tree to grade (default: this repo)")
    ap.add_argument("--fn-allow", default=None,
                    help="the function freeze file (default: function-size.allow beside "
                         "this script for the hub, <root>/function-size.allow otherwise)")
    ap.add_argument("--file-allow", default=None,
                    help="the file freeze file (default: file-size.allow beside this "
                         "script for the hub, <root>/file-size.allow otherwise)")
    ap.add_argument("--scan", action="append",
                    help="restrict to this top-level directory (repeatable)")
    args = ap.parse_args()

    try:
        # resolve_root, not abspath: a subdirectory root would silently shift every allowlist key.
        root = gate_scope.resolve_root(args.root, ROOT)
    except gate_scope.ScopeError as exc:
        return gate_scope.die(exc)
    hub = root == os.path.abspath(ROOT)
    # A consumer's freeze lives in the consumer, where its own diff shows it.
    fn_allow = args.fn_allow or (FN_ALLOW if hub else os.path.join(root, "function-size.allow"))
    file_allow = args.file_allow or (FILE_ALLOW if hub
                                     else os.path.join(root, "file-size.allow"))

    print("=== code size gate (functions > %d, files > %d) ===" % (LIMIT, FILE_LIMIT))
    if not hub:
        print("  root:       %s" % root)
        print("  fn-allow:   %s" % fn_allow)
        print("  file-allow: %s" % file_allow)
    # A redefined name keeps its longest body, so a short redefinition cannot hide the offender.
    longest: dict = {}
    for f, n, c in functions(root, args.scan):
        longest[(f, n)] = max(c, longest.get((f, n), 0))
    rc = check_counts("functions", sorted(longest.items()),
                      load_counts(fn_allow, 2, FN_FMT), LIMIT, os.path.basename(fn_allow))
    rc |= check_counts("files", [((f,), n) for f, n in files(root, args.scan)],
                       load_counts(file_allow, 1, FILE_FMT), FILE_LIMIT,
                       os.path.basename(file_allow))
    if rc == 0:
        print("OK: no new or grown oversized functions or files")
    return rc


if __name__ == "__main__":
    sys.exit(main())
