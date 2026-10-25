#!/usr/bin/env python3
"""Cyclomatic complexity and nesting depth of every function in verify_code_size's scan set (code-complexity.allow).

docs/code-quality-tooling.md#shell-complexity-code-complexity
"""
import argparse
import ast
import functools
import os
import re
import subprocess
import sys
from collections.abc import Callable, Iterable, Iterator, Sequence

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_scope
from quality_allow import check_counts, load_counts
from verify_code_size import ROOT, code_lines, scan, shell_functions

HERE = os.path.dirname(os.path.abspath(__file__))
ALLOW = os.path.join(HERE, "code-complexity.allow")
EXCLUDE = ("third_party",)
ALLOW_FMT = "<path> | <function> | cc|nesting | <count> | <reason>"
CC_LIMIT = int(os.environ.get("COMPLEXITY_LIMIT", "15"))
NEST_LIMIT = int(os.environ.get("NESTING_LIMIT", "5"))
TOKEN = re.compile(r"\n|\$\(|&&|\|\||;;&|;;|;&|[();|&]|(?:[^\s;()|&$]|\$(?!\())+")
BRANCH = {"if", "elif", "while", "until", "for", "&&", "||"}
OPEN = {"if", "for", "while", "until", "select", "case", "{"}
CLOSE = {"fi", "done", "esac", "}"}
CASE_END = {";;", ";&", ";;&"}
KEYWORDS = (BRANCH | OPEN | CLOSE) - {"{", "}", "&&", "||"}
CMD_OPS = {"\n", ";", ";;", ";&", ";;&", "&&", "||", "|", "&", "(", "$(", "{"}
CMD_KW = {"if", "elif", "while", "until", "then", "else", "do", "!", "time"}
DELIM = " \t\n;"
METRICS = ("cc", "nesting")
PY_DEF = (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)
PY_BRANCH = (ast.If, ast.IfExp, ast.For, ast.AsyncFor, ast.While, ast.With, ast.AsyncWith)
PY_BLOCK = PY_BRANCH + (ast.Try, ast.Match)
CaseFrame = list[int | str]
Scan = Callable[[str], Iterable[tuple[str, str]]]


def shell_code(body_lines: Sequence[str]) -> str:
    """The code text of a function: heredoc bodies dropped, comments and quotes blanked."""
    return "\n".join(code_lines(body_lines))


class _Walker:
    """Token state of one shell body; case frames tell a case arm's ')' from $(...)'s."""

    def __init__(self) -> None:
        self.cc, self.depth, self.top, self.parens, self.frames = 1, 0, 0, 0, []
        self.cmd = True

    def word(self, tok: str, delimited: bool) -> str:
        """A reserved word out of command position, or a glued `}` as in `${x:-$(cmd)}`, is ordinary text."""
        if tok in KEYWORDS and not self.cmd:
            return ""
        if tok == "}" and not delimited:
            return ""
        return tok

    def frame(self) -> CaseFrame | None:
        return self.frames[-1] if self.frames else None

    def arm_opens(self, tok: str) -> bool:
        f = self.frame()
        return tok == ")" and f is not None and f[1] == "pattern" and self.parens == f[0]

    def paren_delta(self, tok: str, arm: bool) -> int:
        f = self.frame()
        if tok in ("(", "$(") and not (f and f[1] == "pattern"):
            return 1
        if tok == ")" and not arm and self.parens > 0:
            return -1
        return 0

    def case_state(self, tok: str, arm: bool) -> None:
        f = self.frame()
        if tok == "case":
            self.frames.append([self.parens, "word"])
        elif f is None:
            return
        elif tok == "esac":
            self.frames.pop()
        elif arm:
            f[1] = "body"
        elif tok in CASE_END or (tok == "in" and f[1] == "word"):
            f[1] = "pattern"

    def feed(self, raw: str, delimited: bool) -> None:
        cmd, tok = self.cmd, self.word(raw, delimited)
        arm = self.arm_opens(tok)
        self.cc += tok in BRANCH or arm
        self.depth += (tok in OPEN) - (tok in CLOSE)
        self.top = max(self.top, self.depth)
        self.parens += self.paren_delta(tok, arm)
        self.case_state(tok, arm)
        self.cmd = tok in CMD_OPS or arm or (cmd and tok in CMD_KW)


def shell_metrics(body_lines: Sequence[str]) -> tuple[int, int]:
    """(cyclomatic complexity, nesting depth) of one shell function body."""
    w = _Walker()
    code = shell_code(body_lines)
    for m in TOKEN.finditer(code):
        w.feed(m.group(), m.start() == 0 or code[m.start() - 1] in DELIM)
    return w.cc, max(w.top - 1, 0)


def _py_paths(node: ast.AST) -> int:
    """Decision points one AST node contributes."""
    if isinstance(node, PY_BRANCH):
        return 1
    if isinstance(node, ast.Try):
        return max(1, len(node.handlers))
    if isinstance(node, ast.Match):
        return len(node.cases)
    if isinstance(node, ast.BoolOp):
        return len(node.values) - 1
    if isinstance(node, ast.comprehension):
        return len(node.ifs)
    return 0


def py_metrics(node: ast.AST) -> tuple[int, int]:
    """(cyclomatic complexity, nesting depth) of one def, nested defs excluded; an elif keeps its parent's depth."""
    cc, top = 1, 0

    def walk(n: ast.AST, depth: int) -> None:
        nonlocal cc, top
        for child in ast.iter_child_nodes(n):
            if isinstance(child, PY_DEF):
                continue
            cc += _py_paths(child)
            chained = isinstance(child, ast.If) and getattr(n, "orelse", None) == [child]
            d = depth + (isinstance(child, PY_BLOCK) and not chained)
            top = max(top, d)
            walk(child, d)
    walk(node, 0)
    return cc, top


def py_functions(path: str, rel: str) -> Iterator[tuple[str, str, int, int]]:
    """Yield (rel, qualified_name, cc, nesting) for every def in one Python file."""
    try:
        with open(path, encoding="utf-8", errors="replace") as source:
            tree = ast.parse(source.read())
    except (OSError, SyntaxError):
        return

    def walk(node: ast.AST, prefix: str) -> Iterator[tuple[str, str, int, int]]:
        for child in ast.iter_child_nodes(node):
            if isinstance(child, ast.ClassDef):
                yield from walk(child, prefix + child.name + ".")
            elif isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                yield (rel, prefix + child.name) + py_metrics(child)
                yield from walk(child, prefix + child.name + ".")
    yield from walk(tree, "")


def _tracked(root: str, *suffixes: str) -> Iterator[tuple[str, str]]:
    """Yield (path, rel) per tracked file with one of `suffixes`; ls-files keeps submodules and build output out."""
    out = subprocess.run(["git", "-C", root, "ls-files", "-z", "--"]
                         + ["*" + s for s in suffixes],
                         capture_output=True, text=True, check=False)
    if out.returncode != 0:
        sys.stderr.write(f"ERROR: {root} is not a git checkout; --root must be one\n")
        raise SystemExit(2)
    for rel in sorted(out.stdout.split("\0")):
        head = rel.split("/", 1)[0]
        if rel and not (head in EXCLUDE and rel != head):
            yield os.path.join(root, rel), rel


def scanner(root: str) -> Scan:
    """The (path, rel) source: verify_code_size's walk under the hub, every tracked file elsewhere."""
    if root == os.path.abspath(ROOT):
        return scan
    return functools.partial(_tracked, root)


def measure(scan: Scan) -> Iterator[tuple[str, str, int, int]]:
    """Yield (rel, name, cc, nesting) for every function `scan` reaches."""
    for path, rel in scan(".sh"):
        for _rel, name, _start, body in shell_functions(path, rel):
            yield (rel, name) + shell_metrics(body)
    for path, rel in scan(".py"):
        yield from py_functions(path, rel)


def check_rows(frozen: dict[tuple[str, ...], int], allow_name: str) -> int:
    """1 if any frozen key is not `<path> | <function> | cc|nesting`, naming each bad row."""
    rc = 0
    for key in sorted(frozen):
        if key[2] not in METRICS:
            rc = 1
            sys.stderr.write(
                f"FAIL: {allow_name} row '{' | '.join(key)}' must name a metric column "
                f"({' or '.join(METRICS)}).\n"
            )
    return rc


def main() -> int:
    ap = argparse.ArgumentParser(description="Complexity and nesting of every shell and "
                                             "Python function, under the allow contract.")
    ap.add_argument("--root", default=None,
                    help="the tree to grade (default: this repo)")
    ap.add_argument("--allow", default=None,
                    help="the freeze file (default: code-complexity.allow beside this "
                         "script for the hub, <root>/code-complexity.allow otherwise)")
    args = ap.parse_args()

    try:
        # resolve_root, not abspath: a subdirectory root would silently shift every allowlist key.
        root = gate_scope.resolve_root(args.root, ROOT)
    except gate_scope.ScopeError as exc:
        return gate_scope.die(exc)
    # A consumer's freeze lives in the consumer, where its own diff shows it.
    allow = args.allow or (ALLOW if root == os.path.abspath(ROOT)
                           else os.path.join(root, "code-complexity.allow"))
    allow_name = os.path.basename(allow)

    print(f"=== code complexity gate (cc > {CC_LIMIT}, nesting > {NEST_LIMIT}) ===")
    if root != os.path.abspath(ROOT):
        print(f"  root: {root}")
        print(f"  allow: {allow}")
    worst = {}
    for rel, name, cc, nest in measure(scanner(root)):
        was = worst.get((rel, name), (0, 0))
        worst[(rel, name)] = (max(cc, was[0]), max(nest, was[1]))
    frozen = load_counts(allow, 3, ALLOW_FMT)
    rc = check_rows(frozen, allow_name)
    for metric, limit, unit, i in (("cc", CC_LIMIT, "paths", 0),
                                   ("nesting", NEST_LIMIT, "levels", 1)):
        items = [((f, n, metric), v[i]) for (f, n), v in sorted(worst.items())]
        rc |= check_counts(metric, items,
                           {k: c for k, c in frozen.items()
                            if k[2] == metric},
                           limit, allow_name, unit)
    if rc == 0:
        print("OK: no new or grown complexity offenders")
    return rc


if __name__ == "__main__":
    sys.exit(main())
