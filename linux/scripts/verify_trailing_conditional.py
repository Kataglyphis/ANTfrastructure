#!/usr/bin/env python3
"""Fail on a NEW shell function whose LAST statement is a trailing conditional -- a
top-level `&&` list or a bare test -- whose false arm returns 1 on the "nothing to
do" path and kills the caller under `set -e`. shellcheck has no such check.
Predicates whose status IS the answer are frozen two-way in trailing-conditional.allow.
docs/code-quality-tooling.md#trailing-conditional-returns-trailing-conditional"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from quality_allow import check_keys, load_keys  # noqa: E402
from verify_code_size import ROOT, code_lines, shell_functions  # noqa: E402

ALLOW = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "trailing-conditional.allow")
SCAN = "linux"
SKIP_DIRS = {".git", "__pycache__", "patches", "node_modules"}
CONT_END = ("\\", "&&", "||", "|", "{", "(", "then", "do", "else")
TEST_HEAD = ("[", "[[", "test", "!")


def top_ops(code):
    """Yield (index, op) for `;`, `&&`, `||`, `|` at paren depth 0 outside `[[ ]]`.
    Quotes and comments are already gone; `[[ a =~ (x|y) ]]` must not read as a pipe."""
    depth = bracket = i = 0
    while i < len(code):
        two, one = code[i:i + 2], code[i]
        if two == "[[":
            bracket += 1
            i += 2
            continue
        if two == "]]" and bracket:
            bracket -= 1
            i += 2
            continue
        if one == "(":
            depth += 1
        elif one == ")":
            depth = max(0, depth - 1)
        elif not depth and not bracket:
            if two in ("&&", "||"):
                yield i, two
                i += 2
                continue
            if one in (";", "|"):
                yield i, one
        i += 1


def last_statement(body_lines):
    """(statement, index into the body) for the final statement of a function, as stripped
    code: the last non-empty line, joined backwards over operator/backslash continuations."""
    lines = code_lines(body_lines[1:-1]) if len(body_lines) > 2 else []
    live = [i for i, l in enumerate(lines) if l.strip()]
    if not live:
        return "", 0
    end = start = live[-1]
    while start > 0 and lines[start - 1].strip().endswith(CONT_END):
        start -= 1
    return " ".join(l.strip() for l in lines[start:end + 1]).strip(), end + 1


def is_finding(stmt):
    """True when `stmt`'s exit status is a condition's rather than an action's."""
    for cut in reversed([i for i, op in top_ops(stmt) if op == ";"]):
        if stmt[cut + 1:].strip():
            stmt = stmt[cut + 1:].strip()
            break
    ops = {op for _i, op in top_ops(stmt)}
    if "||" in ops:
        return False
    if "&&" in ops:
        return True
    words = stmt.split()
    return bool(words) and words[0] in TEST_HEAD


def sites():
    """Yield (relpath, function) for every trailing-conditional function under linux/."""
    for base, dirs, files in os.walk(os.path.join(ROOT, SCAN)):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for fn in sorted(files):
            if not fn.endswith(".sh"):
                continue
            path = os.path.join(base, fn)
            rel = os.path.relpath(path, ROOT)
            for _r, name, start, body in shell_functions(path, rel):
                stmt, off = last_statement(body)
                if stmt and is_finding(stmt):
                    yield rel, name, "{}:{}  {}".format(rel, start + off, stmt)


def main():
    found = sorted(sites())
    allow = load_keys(ALLOW)
    keys = {"{}\t{}".format(f, n) for f, n, _s in found}
    print("=== trailing-conditional return gate ===")
    print("  {} function(s) ending on a conditional; {} frozen in {}".format(
        len(keys), len(allow), os.path.basename(ALLOW)))

    def _site(k):
        f, n = k.split("\t")
        at = next((s for ff, nn, s in found if ff == f and nn == n), f)
        return "{}  ->  {}".format(n, at[:110])

    rc = check_keys(keys, allow,
                    "NEW trailing-conditional return(s) -- the false arm returns 1 and\n"
                    "  kills the caller under set -e. End on the action, or make the\n"
                    "  intent explicit:\n\n    [ -n \"${x}\" ] || return 0\n    do_thing",
                    "STALE entr(ies) -- the function no longer ends on a conditional,"
                    " delete the line:", _site)
    if rc == 0:
        print("OK: no new trailing-conditional returns")
    return rc


if __name__ == "__main__":
    sys.exit(main())
