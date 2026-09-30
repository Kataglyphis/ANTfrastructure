#!/usr/bin/env python3
"""Fail on a NEW shell function returning a condition's status, whose false arm kills a `set -e` caller.

Predicates are frozen in trailing-conditional.allow; see docs/code-quality-tooling.md#trailing-conditional-returns-trailing-conditional"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from quality_allow import check_keys, load_keys  # noqa: E402

import gate_scope  # noqa: E402
from verify_code_size import DEF, ROOT, code_lines, shell_functions  # noqa: E402

ALLOW = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "trailing-conditional.allow")
SCAN = ("linux",)
SKIP_DIRS = {".git", "__pycache__", "patches", "node_modules"}
CONT_END = ("\\", "&&", "||", "|", "(", "then", "do", "else")
TEST_HEAD = ("[", "[[", "test", "!")
CLOSERS = ("done", "fi", "esac", "}")
CALL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)(?:\s|$)")


def top_ops(code):
    """Yield (index, op) for `;`, `&&`, `||`, `|` at paren depth 0 and outside `[[ ]]`, where `|` is regex."""
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
    """code_lines of the body without its head and closing brace, so one-line and multi-line bodies match."""
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
    """(statement, first, last index) of the last statement at or before `end`, continuations joined."""
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
    """The last inner statement of a `{ ...; }` group, whose status it returns, or ""."""
    if not (stmt.startswith("{") and stmt.endswith("}")):
        return ""
    inner = stmt[1:-1].strip().rstrip(";").strip()
    parts = [p for p in (q.strip() for q in inner.split(";")) if p]
    return parts[-1] if parts else ""


def closes_a_block(stmt):
    """Is this a bare block closer, which returns its block's status (unlike `done | sort -u`)?"""
    return is_simple(stmt) and stmt.split()[0] in CLOSERS


def returned_statement(lines):
    """(statement, line offset) whose status the function returns, stepping into a closed block."""
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
    """{function: site}: direct findings, then functions tail-calling one, to a fixed point."""
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


def _walk_scan(root, tops):
    """Every *.sh under the named top-level directories."""
    for top in tops:
        for base, dirs, files in os.walk(os.path.join(root, top)):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            for fn in sorted(files):
                if fn.endswith(".sh"):
                    # Posix-spelled keys, or Windows backslashes break every frozen row.
                    yield os.path.relpath(os.path.join(base, fn), root).replace(os.sep, "/")


def scan_paths(root, scan):
    """Files to grade: --scan's walk, the hub's historical walk, or another root's tracked *.sh."""
    if scan:
        return sorted(_walk_scan(root, scan))
    if gate_scope.is_hub(root, ROOT):
        return sorted(_walk_scan(root, SCAN))
    return gate_scope.tracked(root, ['*.sh'])


def sites(root, rels):
    """Yield (relpath, function, site) for every trailing-conditional function found."""
    for rel in rels:
        for name, site in file_sites(os.path.join(root, rel), rel).items():
            yield rel, name, site


def main():
    ap = argparse.ArgumentParser(description="Fail on new trailing-conditional returns.")
    ap.add_argument("--root", default=None,
                    help="the tree to grade (default: this repo)")
    ap.add_argument("--allow", default=None,
                    help="the freeze file (default: trailing-conditional.allow beside "
                         "this script for the hub, <root>/trailing-conditional.allow "
                         "otherwise)")
    ap.add_argument("--scan", action="append",
                    help="restrict to this top-level directory (repeatable)")
    args = ap.parse_args()

    try:

        # resolve_root, not abspath: a subdirectory root would silently shift every allowlist key.

        root = gate_scope.resolve_root(args.root, ROOT)

    except gate_scope.ScopeError as exc:

        return gate_scope.die(exc)
    # A consumer's freeze lives in the consumer, where its own diff shows it.
    allow_file = args.allow or (ALLOW if root == os.path.abspath(ROOT)
                                else os.path.join(root, "trailing-conditional.allow"))

    found = sorted(sites(root, scan_paths(root, args.scan)))
    allow = load_keys(allow_file)
    keys = {"{}\t{}".format(f, n) for f, n, _s in found}
    print("=== trailing-conditional return gate ===")
    if root != os.path.abspath(ROOT):
        print("  root: {}".format(root))
        print("  allow: {}".format(allow_file))
    print("  {} function(s) ending on a conditional; {} frozen in {}".format(
        len(keys), len(allow), os.path.basename(allow_file)))

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
