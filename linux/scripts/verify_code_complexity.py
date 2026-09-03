#!/usr/bin/env python3
"""Cyclomatic complexity and nesting depth of every shell and Python function in the
code-size scan set, under the four-way allow contract (code-complexity.allow).
Heredoc bodies, comments and quoted text are invisible to the shell counter; a
reserved word counts only in command position, case arms count, $(...)'s ')' does not.
docs/code-quality-tooling.md#shell-complexity-code-complexity"""
import ast
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from quality_allow import check_counts, load_counts  # noqa: E402
from verify_code_size import scan, shell_functions  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ALLOW = os.path.join(HERE, "code-complexity.allow")
CC_LIMIT = int(os.environ.get("COMPLEXITY_LIMIT", "15"))
NEST_LIMIT = int(os.environ.get("NESTING_LIMIT", "5"))
HEREDOC = re.compile(r"(?<!<)<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
TOKEN = re.compile(r"\n|\$\(|&&|\|\||;;&|;;|;&|[();|&]|(?:[^\s;()|&$]|\$(?!\())+")
QUOTE = {"'": "sq", '"': "dq"}
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


def shell_code(body_lines):
    """The code text of a function: heredoc bodies dropped, comments and quotes blanked."""
    stack, pending, out = [], [], []
    for line in body_lines:
        if pending:
            if line.strip() == pending[0]:
                pending.pop(0)
            continue
        code, docs = strip_line(line, stack)
        pending.extend(docs)
        out.append(code)
    return "\n".join(out)


class _Walker:
    """Token-level state of one shell body: block depth, ( ) depth, whether the next
    token sits in command position, and case frames ([parens_at_entry,
    word|pattern|body]) so a case arm's ')' is told from $(...)'s."""

    def __init__(self):
        self.cc, self.depth, self.top, self.parens, self.frames = 1, 0, 0, 0, []
        self.cmd = True

    def word(self, tok, delimited):
        """A reserved word out of command position, or a `}` glued to what precedes it
        (the tail of `${x:-$(cmd)}`), is ordinary text."""
        if tok in KEYWORDS and not self.cmd:
            return ""
        if tok == "}" and not delimited:
            return ""
        return tok

    def frame(self):
        return self.frames[-1] if self.frames else None

    def arm_opens(self, tok):
        f = self.frame()
        return tok == ")" and f is not None and f[1] == "pattern" and self.parens == f[0]

    def paren_delta(self, tok, arm):
        f = self.frame()
        if tok in ("(", "$(") and not (f and f[1] == "pattern"):
            return 1
        if tok == ")" and not arm and self.parens > 0:
            return -1
        return 0

    def case_state(self, tok, arm):
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

    def feed(self, raw, delimited):
        cmd, tok = self.cmd, self.word(raw, delimited)
        arm = self.arm_opens(tok)
        self.cc += tok in BRANCH or arm
        self.depth += (tok in OPEN) - (tok in CLOSE)
        self.top = max(self.top, self.depth)
        self.parens += self.paren_delta(tok, arm)
        self.case_state(tok, arm)
        self.cmd = tok in CMD_OPS or arm or (cmd and tok in CMD_KW)


def shell_metrics(body_lines):
    """(cyclomatic complexity, nesting depth) of one shell function body."""
    w = _Walker()
    code = shell_code(body_lines)
    for m in TOKEN.finditer(code):
        w.feed(m.group(), m.start() == 0 or code[m.start() - 1] in DELIM)
    return w.cc, max(w.top - 1, 0)


def _py_paths(node):
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


def py_metrics(node):
    """(cyclomatic complexity, nesting depth) of one Python def, nested defs excluded.
    An elif is an If inside its parent's orelse and continues that parent's depth."""
    cc, top = 1, 0

    def walk(n, depth):
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


def py_functions(path, rel):
    """Yield (rel, qualified_name, cc, nesting) for every def in one Python file."""
    try:
        tree = ast.parse(open(path, encoding="utf-8", errors="replace").read())
    except (OSError, SyntaxError):
        return

    def walk(node, prefix):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, ast.ClassDef):
                yield from walk(child, prefix + child.name + ".")
            elif isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                yield (rel, prefix + child.name) + py_metrics(child)
                yield from walk(child, prefix + child.name + ".")
    yield from walk(tree, "")


def measure():
    """Yield (rel, name, cc, nesting) for every function in the scan set."""
    for path, rel in scan(".sh"):
        for _rel, name, _start, body in shell_functions(path, rel):
            yield (rel, name) + shell_metrics(body)
    for path, rel in scan(".py"):
        yield from py_functions(path, rel)


def check_rows(frozen):
    """1 if any frozen key is not `<path> | <function> | cc|nesting`, naming each bad row."""
    rc = 0
    for key in sorted(frozen):
        if len(key) != 3 or key[2] not in METRICS:
            rc = 1
            sys.stderr.write("FAIL: %s row '%s' must name a metric column (%s) -- "
                             "%d key field(s) before the count.\n"
                             % (os.path.basename(ALLOW), " | ".join(key),
                                " or ".join(METRICS), len(key)))
    return rc


def main():
    print("=== code complexity gate (cc > %d, nesting > %d) ===" % (CC_LIMIT, NEST_LIMIT))
    worst = {}
    for rel, name, cc, nest in measure():
        was = worst.get((rel, name), (0, 0))
        worst[(rel, name)] = (max(cc, was[0]), max(nest, was[1]))
    frozen = load_counts(ALLOW)
    rc = check_rows(frozen)
    for metric, limit, unit, i in (("cc", CC_LIMIT, "paths", 0),
                                   ("nesting", NEST_LIMIT, "levels", 1)):
        items = [((f, n, metric), v[i]) for (f, n), v in sorted(worst.items())]
        rc |= check_counts(metric, items,
                           {k: c for k, c in frozen.items()
                            if len(k) == 3 and k[2] == metric},
                           limit, os.path.basename(ALLOW), unit)
    if rc == 0:
        print("OK: no new or grown complexity offenders")
    return rc


if __name__ == "__main__":
    sys.exit(main())
