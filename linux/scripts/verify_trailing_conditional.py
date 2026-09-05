#!/usr/bin/env python3
"""Fail on a NEW shell function whose returned status is a CONDITION's -- a trailing
`&&` list, a bare test, the last arm of a `||`, the tail of a `do`/`then`/`in` block,
or a bare call to a same-file function that is one of those -- because its false arm
returns 1 on the "nothing to do" path and kills the caller under `set -e`.
Predicates whose status IS the answer are frozen two-way in trailing-conditional.allow.
docs/code-quality-tooling.md#trailing-conditional-returns-trailing-conditional"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from quality_allow import check_keys, load_keys  # noqa: E402
from verify_code_size import DEF, ROOT, code_lines, shell_functions  # noqa: E402

ALLOW = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "trailing-conditional.allow")
SCAN = "linux"
SKIP_DIRS = {".git", "__pycache__", "patches", "node_modules"}
CONT_END = ("\\", "&&", "||", "|", "(", "then", "do", "else")
TEST_HEAD = ("[", "[[", "test", "!")
CLOSERS = ("done", "fi", "esac", "}")
CALL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)(?:\s|$)")


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


def body_lines(body):
    """The function's own code lines: stripping is `verify_code_size.code_lines`, then
    the definition head goes off the first line and the closing brace off the last, so a
    one-line `f() { …; }` presents the same body as a multi-line one."""
    lines = code_lines(body)
    if not lines:
        return []
    head = DEF.match(lines[0])
    if head:
        lines[0] = lines[0][head.end():]
    brace = lines[-1].rfind("}")
    if brace >= 0:
        lines[-1] = lines[-1][:brace]
    return lines


def last_statement(lines, end):
    """(statement, first index, last index) for the last live statement at or before
    `end`, joined backwards over operator/backslash continuations; ("", -1, -1) if none."""
    while end >= 0 and not lines[end].strip():
        end -= 1
    if end < 0:
        return "", -1, -1
    start = end
    while start > 0 and lines[start - 1].strip().endswith(CONT_END):
        start -= 1
    stmt = " ".join(l.strip() for l in lines[start:end + 1]).strip()
    return stmt.rstrip(";").strip(), start, end


def is_simple(stmt):
    """No top-level `;`, `&&`, `||` or `|`: the statement is one command."""
    return not any(True for _pair in top_ops(stmt))


def unwrap_group(stmt):
    """`{ a; [ -n "$x" ]; }` returns its LAST inner statement's status, so that is what
    the verdict is about. Returns the inner text, or "" when stmt is not a group."""
    if not (stmt.startswith("{") and stmt.endswith("}")):
        return ""
    inner = stmt[1:-1].strip().rstrip(";").strip()
    parts = [p for p in (q.strip() for q in inner.split(";")) if p]
    return parts[-1] if parts else ""


def closes_a_block(stmt):
    """A bare `done`/`fi`/`esac`/`}` returns the status of the block it closes, so the
    verdict is inside; the same word in a pipeline (`done | sort -u`) does not."""
    return is_simple(stmt) and stmt.split()[0] in CLOSERS


def returned_statement(lines):
    """(statement, line offset) whose status the function returns: its last statement,
    stepping THROUGH a block closer into the last statement of the block itself."""
    end = len(lines) - 1
    while end >= 0:
        stmt, start, last = last_statement(lines, end)
        if last < 0:
            break
        if stmt and not closes_a_block(stmt):
            return stmt, last
        end = start - 1
    return "", 0


def is_finding(stmt):
    """True when `stmt`'s exit status is a condition's rather than an action's."""
    inner = unwrap_group(stmt)
    if inner:
        return is_finding(inner)
    for cut in reversed([i for i, op in top_ops(stmt) if op == ";"]):
        if stmt[cut + 1:].strip():
            stmt = stmt[cut + 1:].strip()
            break
    ops = [(i, op) for i, op in top_ops(stmt)]
    fallback = max([i for i, op in ops if op == "||"], default=-1)
    if fallback >= 0:
        return is_finding(stmt[fallback + 2:].strip())
    if any(op == "&&" for _i, op in ops):
        return True
    words = stmt.split()
    return bool(words) and words[0] in TEST_HEAD


def delegate(stmt):
    """The same-file function a bare trailing call hands its status to, or ""."""
    if not is_simple(stmt):
        return ""
    m = CALL.match(stmt)
    return m.group(1) if m else ""


def file_sites(path, rel):
    """{function: site} for one file: the direct findings, then every function whose
    tail is a bare call to one of them, to a fixed point inside the file."""
    found, calls = {}, {}
    for _r, name, start, body in shell_functions(path, rel):
        stmt, off = returned_statement(body_lines(body))
        if not stmt:
            continue
        site = "{}:{}  {}".format(rel, start + off, stmt)
        if is_finding(stmt):
            found[name] = site
        elif delegate(stmt):
            calls[name] = (delegate(stmt), site)
    while True:
        hops = [n for n, (callee, _s) in calls.items() if callee in found and callee != n]
        if not hops:
            return found
        for n in hops:
            found[n] = calls.pop(n)[1]


def sites():
    """Yield (relpath, function, site) for every trailing-conditional function under linux/."""
    for base, dirs, files in os.walk(os.path.join(ROOT, SCAN)):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for fn in sorted(files):
            if not fn.endswith(".sh"):
                continue
            path = os.path.join(base, fn)
            rel = os.path.relpath(path, ROOT)
            for name, site in file_sites(path, rel).items():
                yield rel, name, site


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
