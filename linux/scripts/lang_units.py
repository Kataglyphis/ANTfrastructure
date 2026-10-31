# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Report-only units (Rust, Dart, C/C++ function extents; Python duplicate units); blind to macros, #if-split headers, K&R C and Dart arrow bodies.

docs/code-quality-tooling.md#extra-language-readers-report-only
"""
from __future__ import annotations

import ast
import bisect
import io
import re
import tokenize
from collections.abc import Callable, Iterator
from pathlib import Path

LANGUAGES = {".rs": "rust", ".dart": "dart", ".c": "c-cpp", ".cc": "c-cpp", ".cpp": "c-cpp",
             ".h": "c-cpp", ".hpp": "c-cpp", ".ixx": "c-cpp"}
_C_PREFIX = r"(?:(?<![\w])(?:u8|[uUL]))?"
OPENERS = {
    "c-cpp": re.compile(
        r"(?P<line>//)|(?P<block>/\*)|(?P<directive>^[ \t]*\#)"
        r"|(?P<craw>" + _C_PREFIX + r'R"(?P<delim>[^()\\\s]{0,16})\()'
        r'|(?P<cstr>' + _C_PREFIX + r'")'
        r"|(?P<cchr>(?:(?<![\w])(?:u8|[uUL])|(?<![\w]))')", re.MULTILINE),
    "rust": re.compile(
        r"(?P<line>//)|(?P<nested>/\*)"
        r'|(?P<rraw>(?<![\w])(?:br|cr|r)(?P<hashes>#*)")'
        r'|(?P<rstr>(?:(?<![\w])[bc])?")'
        r"|(?P<rchr>(?:(?<![\w])b)?')"),
    "dart": re.compile(
        r"(?P<line>//)|(?P<nested>/\*)"
        r"""|(?P<draw>(?<![\w$])r(?P<quote>'''|\"\"\"|'|"))"""
        r"""|(?P<dstr>'''|\"\"\"|'|")"""),
}
_DART_INNER = re.compile(OPENERS["dart"].pattern + r"|(?P<brace>[{}])")
_C_CHAR = re.compile(r"(?:u8|[uUL])?'(?:\\.|[^\\'\n])*'")
_RUST_CHAR = re.compile(r"b?'(?:\\(?:u\{[0-9A-Fa-f]{1,6}\}|x[0-9A-Fa-f]{2}|.)|[^\\'\n])'")
_NOT_BLANK = re.compile(r"[^\n]")
_STRUCTURE = re.compile(r"[{}();]")
FN_RUST = re.compile(r"\bfn\s+([A-Za-z_]\w*)")
GETTER = re.compile(r"\bget\s+([A-Za-z_$][\w$]*)\s*$")
NAME_BEFORE = re.compile(r"(operator\s*(?:\(\s*\)|[^\s(\w]+)|~?[A-Za-z_$][\w$]*"
                         r"(?:\s*(?:::|\.)\s*~?[A-Za-z_$][\w$]*)*)\s*$")
# What may follow a parameter list before the body: qualifiers, a return type, async markers or an initialiser list.
TRAIL = re.compile(r"(?:\s|const\b|volatile\b|mutable\b|override\b|final\b|try\b"
                   r"|noexcept\b(?:\s*\([^()]*\))?|throw\s*\([^()]*\)|&&?|\[\[[^\]]*\]\]"
                   r"|->[^;{}]*|requires\b[^;{}]*|async\*?|sync\*|:.*)*", re.DOTALL)
INIT_TAIL = re.compile(r":[^;]*[\w>]\s*$")
NOT_NAMES = {"if", "for", "while", "switch", "catch", "return", "sizeof", "alignof", "alignas",
             "decltype", "noexcept", "requires", "throw", "static_assert", "typeof", "defined",
             "__attribute__", "__declspec", "assert"}


def _line_end(text: str, m: re.Match[str]) -> int:
    end = text.find("\n", m.end())
    return len(text) if end < 0 else end


def _block_end(text: str, m: re.Match[str], nested: bool) -> int:
    depth, k = 1, m.end()
    while k < len(text):
        if text.startswith("*/", k):
            depth -= 1
            k += 2
            if depth == 0:
                return k
        elif nested and text.startswith("/*", k):
            depth += 1
            k += 2
        else:
            k += 1
    return len(text)


def _directive_end(text: str, m: re.Match[str]) -> int:
    """A preprocessor line, carried on while it ends in a backslash."""
    end = _line_end(text, m)
    while end < len(text) and text[:end].rstrip(" \t\r").endswith("\\"):
        nxt = text.find("\n", end + 1)
        end = len(text) if nxt < 0 else nxt
    return end


def _quoted_end(text: str, k: int, quote: str, multiline: bool) -> int:
    """Index past the closing `quote`, with backslash escapes; a one-line string stops at its newline."""
    while k < len(text):
        if text[k] == "\\":
            k += 2
        elif text.startswith(quote, k):
            return k + len(quote)
        elif text[k] == "\n" and not multiline:
            return k
        else:
            k += 1
    return len(text)


def _raw_end(text: str, k: int, close: str) -> int:
    end = text.find(close, k)
    return len(text) if end < 0 else end + len(close)


def _char_end(text: str, m: re.Match[str], literal: re.Pattern[str]) -> int:
    """A char literal's end; an unmatched quote (a lifetime or digit separator) is a single code char."""
    lit = literal.match(text, m.start())
    return lit.end() if lit else m.end()


def _interp_end(text: str, k: int) -> int:
    """Index past the `}` closing a Dart `${...}` that opened before `k`, nested strings included."""
    depth = 0
    while True:
        m = _DART_INNER.search(text, k)
        if m is None:
            return len(text)
        if m.lastgroup != "brace":
            k = literal_end(text, m)
        elif m.group() == "{":
            depth, k = depth + 1, m.end()
        elif depth:
            depth, k = depth - 1, m.end()
        else:
            return m.end()


def _dart_string_end(text: str, m: re.Match[str]) -> int:
    quote, k = m.group(), m.end()
    while k < len(text):
        if text[k] == "\\":
            k += 2
        elif text.startswith(quote, k):
            return k + len(quote)
        elif text[k] == "\n" and len(quote) == 1:
            return k
        elif text.startswith("${", k):
            k = _interp_end(text, k + 2)
        else:
            k += 1
    return len(text)


def _dart_raw_end(text: str, m: re.Match[str]) -> int:
    quote = m.group("quote")
    if len(quote) == 3:
        return _raw_end(text, m.end(), quote)
    end = _raw_end(text, m.end(), quote)
    newline = text.find("\n", m.end())
    return newline if 0 <= newline < end else end


_ENDS: dict[str, Callable[[str, re.Match[str]], int]] = {
    "line": _line_end,
    "block": lambda t, m: _block_end(t, m, False),
    "nested": lambda t, m: _block_end(t, m, True),
    "directive": _directive_end,
    "craw": lambda t, m: _raw_end(t, m.end(), ")" + m.group("delim") + '"'),
    "cstr": lambda t, m: _quoted_end(t, m.end(), '"', False),
    "cchr": lambda t, m: _char_end(t, m, _C_CHAR),
    "rraw": lambda t, m: _raw_end(t, m.end(), '"' + m.group("hashes")),
    "rstr": lambda t, m: _quoted_end(t, m.end(), '"', True),
    "rchr": lambda t, m: _char_end(t, m, _RUST_CHAR),
    "draw": _dart_raw_end,
    "dstr": _dart_string_end,
}


def literal_end(text: str, m: re.Match[str]) -> int:
    """Index past the comment or literal an opener match starts."""
    return _ENDS[str(m.lastgroup)](text, m)


def mask(text: str, lang: str) -> str:
    """Comments and literals blanked to spaces with newlines kept, so braces and line numbers stay code-true."""
    opener, out, pos = OPENERS[lang], [], 0
    while (m := opener.search(text, pos)) is not None:
        end = max(literal_end(text, m), m.end())
        out.append(text[pos:m.start()])
        out.append(_NOT_BLANK.sub(" ", text[m.start():end]))
        pos = end
    out.append(text[pos:])
    return "".join(out)


def _paren_groups(header: str) -> Iterator[tuple[int, int]]:
    """(open, close) offsets of each top-level parenthesised group."""
    depth, start = 0, 0
    for i, c in enumerate(header):
        if c == "(":
            start = i if depth == 0 else start
            depth += 1
        elif c == ")" and depth:
            depth -= 1
            if depth == 0:
                yield start, i


def _depth0(text: str) -> str:
    """`text` without its parenthesised groups and template or generic parameter lists."""
    out, depth = [], 0
    for c in text:
        if c in "(<":
            depth += 1
        elif c in ")>" and depth:
            depth -= 1
        elif depth == 0:
            out.append(c)
    return "".join(out)


def c_like_name(header: str) -> tuple[str, int] | None:
    """(name, offset) when `header` is a C, C++ or Dart function signature, else None."""
    for start, end in _paren_groups(header):
        named = NAME_BEFORE.search(header, 0, start)
        if named is None or re.split(r"::|\.", named.group(1))[-1].strip() in NOT_NAMES:
            continue
        if TRAIL.fullmatch(header, end + 1) is None:
            continue
        if "=" in _depth0(header[:named.start()]):
            return None
        return " ".join(named.group(1).split()), named.start(1)
    return None


def _rust_name(header: str) -> tuple[str, int] | None:
    m = FN_RUST.search(header)
    return (m.group(1), m.start(1)) if m else None


def _dart_name(header: str) -> tuple[str, int] | None:
    m = GETTER.search(header)
    return (m.group(1), m.start(1)) if m else c_like_name(header)


def _c_member_init(header: str) -> bool:
    """A `{` after `Foo() : member` initialises the member; the body comes later."""
    return INIT_TAIL.search(header) is not None and c_like_name(header) is not None


NAMERS: dict[str, Callable[[str], tuple[str, int] | None]] = {
    "rust": _rust_name, "dart": _dart_name, "c-cpp": c_like_name}
MEMBER_INIT: dict[str, Callable[[str], bool]] = {
    "rust": lambda _h: False, "dart": lambda _h: False, "c-cpp": _c_member_init}


class _Walk:
    """Brace frames over masked text: a function frame is never descended, a scope frame is."""

    def __init__(self, masked: str, lang: str) -> None:
        self.masked, self.lang = masked, lang
        self.stack: list[tuple[str, str, int]] = []
        self.head = 0
        self.found: list[tuple[str, int, int]] = []

    def scope_level(self) -> bool:
        return not self.stack or self.stack[-1][0] == "scope"

    def open_brace(self, i: int) -> None:
        header = self.masked[self.head:i] if self.scope_level() else None
        if header is None or MEMBER_INIT[self.lang](header):
            self.stack.append(("inner", "", i))
            return
        named = NAMERS[self.lang](header)
        self.stack.append(("fn", named[0], self.head + named[1]) if named else ("scope", "", i))
        self.head = i + 1

    def close_brace(self, i: int) -> None:
        if not self.stack:
            self.head = i + 1
            return
        kind, name, start = self.stack.pop()
        if kind == "fn":
            self.found.append((name, start, i))
        if kind != "inner":
            self.head = i + 1

    def feed(self, c: str, i: int) -> None:
        if c == "(":
            self.stack.append(("paren", "", i))
        elif c == ")":
            if self.stack and self.stack[-1][0] == "paren":
                self.stack.pop()
        elif c == ";":
            self.head = i + 1 if self.scope_level() else self.head
        elif c == "{":
            self.open_brace(i)
        else:
            self.close_brace(i)


def functions(text: str, lang: str) -> list[tuple[str, int, int]]:
    """(name, first_line, line_count) per function body, outermost only, in source order."""
    masked = mask(text, lang)
    walk = _Walk(masked, lang)
    for m in _STRUCTURE.finditer(masked):
        walk.feed(m.group(), m.start())
    starts = [0] + [m.end() for m in re.finditer("\n", masked)]
    out = []
    for name, start, end in walk.found:
        first, last = bisect.bisect_right(starts, start), bisect.bisect_right(starts, end)
        out.append((name, first, last - first + 1))
    return out


def _blank_span(lines: list[list[str]], start: tuple[int, int], end: tuple[int, int],
                stub: str) -> None:
    """Blank a token span in place, leaving `stub` at its start so a string still reads as one."""
    (row, col), (erow, ecol) = start, end
    while row <= erow:
        line = lines[row - 1]
        stop = ecol if row == erow else len(line)
        line[col:stop] = [" "] * (stop - col)
        row, col = row + 1, 0
    first = lines[start[0] - 1]
    first[start[1]:start[1] + len(stub)] = list(stub)


def _python_masked(text: str) -> list[str]:
    """Source lines with comments dropped and every string, f-strings included, reduced to `""`."""
    lines = [list(line) for line in text.split("\n")]
    open_ends = {getattr(tokenize, n) for n in ("FSTRING_START", "TSTRING_START") if hasattr(tokenize, n)}
    close_ends = {getattr(tokenize, n) for n in ("FSTRING_END", "TSTRING_END") if hasattr(tokenize, n)}
    starts: list[tuple[int, int]] = []
    for tok in tokenize.generate_tokens(io.StringIO(text).readline):
        if tok.type == tokenize.COMMENT:
            _blank_span(lines, tok.start, tok.end, "")
        elif tok.type == tokenize.STRING and not starts:
            _blank_span(lines, tok.start, tok.end, '""')
        elif tok.type in open_ends:
            starts.append(tok.start)
        elif tok.type in close_ends and starts:
            begin = starts.pop()
            if not starts:
                _blank_span(lines, begin, tok.end, '""')
    return ["".join(line) for line in lines]


def _outer_defs(node: ast.AST) -> Iterator[ast.FunctionDef | ast.AsyncFunctionDef]:
    for child in ast.iter_child_nodes(node):
        if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
            yield child
        else:
            yield from _outer_defs(child)


def py_units(path: Path) -> list[tuple[int, str]]:
    """Outermost functions with their decorators, the rest chunked on blank lines; an unparsable file has none."""
    text = path.read_text(encoding="utf-8", errors="replace")
    try:
        tree = ast.parse(text)
        lines = _python_masked(text)
    except (SyntaxError, ValueError, tokenize.TokenError):
        return []
    spans = {min([d.lineno for d in n.decorator_list] + [n.lineno]): n.end_lineno or n.lineno
             for n in _outer_defs(tree)}
    units: list[tuple[int, str]] = []
    loose: list[str] = []
    row = 1
    while row <= len(lines):
        if loose and (row in spans or not lines[row - 1].strip()):
            units.append((row - len(loose), "\n".join(loose)))
            loose = []
        if row in spans:
            units.append((row, "\n".join(lines[row - 1:spans[row]])))
            row = spans[row] + 1
            continue
        if lines[row - 1].strip():
            loose.append(lines[row - 1])
        row += 1
    if loose:
        units.append((row - len(loose), "\n".join(loose)))
    return units
