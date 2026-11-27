# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""PowerShell text verify_code_dupes.py reads: literal brackets masked, param blocks marked; see docs/code-quality-tooling.md#powershell-param-blocks-are-idiom"""

from __future__ import annotations

import re

# Masked inside literals and comments, so neither a function's braces nor a param block's parens count them.
PS_LITERAL_BRACKETS = "{}()"
# The keyword only: $param(, -Param ( and .Param( are a variable, an argument and a method call.
PS_PARAM = re.compile(r"(?<![\w$.:-])param\s*\(", re.IGNORECASE)
# Around each param block, so its tokens stay in the idiom census but never in a pair count.
PARAM_OPEN, PARAM_CLOSE = "__param_block_open__", "__param_block_close__"
PARAM_MARKS = (PARAM_OPEN, PARAM_CLOSE)


def _mask_ps_here_char(text: str, chars: list[str], i: int, marker: str | None) -> tuple[int, str, str | None]:
    if marker is None:
        raise ValueError("PowerShell here-string state has no delimiter")
    if i == 0 or text[i - 1] == "\n":
        end = text.find("\n", i)
        end = len(text) if end < 0 else end
        start = i + (len(text[i:end]) - len(text[i:end].lstrip(" \t")))
        if text.startswith(marker, start):
            return start + 2, "code", None
    if text[i] in PS_LITERAL_BRACKETS:
        chars[i] = " "
    return i + 1, "here", marker


def _mask_ps_comment_char(char: str, chars: list[str], i: int) -> tuple[int, str]:
    if char in "\r\n":
        return i + 1, "code"
    if char in PS_LITERAL_BRACKETS:
        chars[i] = " "
    return i + 1, "comment"


def _mask_ps_quote_char(text: str, chars: list[str], i: int, marker: str | None) -> tuple[int, str, str | None]:
    if marker is None:
        raise ValueError("PowerShell quote state has no delimiter")
    char = text[i]
    if char in PS_LITERAL_BRACKETS:
        chars[i] = " "
    if marker == "'" and char == "'" and i + 1 < len(text) and text[i + 1] == "'":
        return i + 2, "quote", marker
    if marker == '"' and char == "`":
        if i + 1 < len(text) and text[i + 1] in PS_LITERAL_BRACKETS:
            chars[i + 1] = " "
        return i + 2, "quote", marker
    if char == marker:
        return i + 1, "code", None
    return i + 1, "quote", marker


def _mask_ps_code_char(text: str, chars: list[str], i: int) -> tuple[int, str, str | None]:
    char = text[i]
    if char == "`" and i + 1 < len(text):
        if text[i + 1] in PS_LITERAL_BRACKETS:
            chars[i + 1] = " "
        return i + 2, "code", None
    if char == "#":
        return i + 1, "comment", None
    if char == "@" and i + 1 < len(text) and text[i + 1] in "'\"":
        end = text.find("\n", i)
        end = len(text) if end < 0 else end
        if not text[i + 2:end].strip(" \t\r"):
            return i + 2, "here", text[i + 1] + "@"
    if char in "'\"":
        return i + 1, "quote", char
    return i + 1, "code", None


def mask_ps_brackets_in_literals(text: str) -> str:
    """The text with every brace and paren inside a string, here-string or comment blanked."""
    chars = list(text)
    state, marker, i = "code", None, 0
    while i < len(text):
        if state == "here":
            i, state, marker = _mask_ps_here_char(text, chars, i, marker)
            continue
        if state == "comment":
            i, state = _mask_ps_comment_char(text[i], chars, i)
            continue
        if state == "quote":
            i, state, marker = _mask_ps_quote_char(text, chars, i, marker)
            continue
        i, state, marker = _mask_ps_code_char(text, chars, i)
    return "".join(chars)


def _paren_close(masked: str, open_at: int) -> int | None:
    """Offset just past the paren closing the one at open_at, or None when the text never closes it."""
    depth = 0
    for i in range(open_at, len(masked)):
        if masked[i] == "(":
            depth += 1
        elif masked[i] == ")":
            depth -= 1
            if depth == 0:
                return i + 1
    return None


def ps_param_spans(masked: str) -> list[tuple[int, int]]:
    """[start, end) of each param(...) block, keyword through closing paren; an unclosed one stays code."""
    spans: list[tuple[int, int]] = []
    pos = 0
    while (m := PS_PARAM.search(masked, pos)) is not None:
        end = _paren_close(masked, m.end() - 1)
        if end is not None:
            spans.append((m.start(), end))
        pos = end or m.end()
    return spans


def _mark_line(piece: str) -> str:
    # A blank or comment line stays one, or it would move a chunk boundary or become tokens.
    if not piece.strip() or piece.lstrip().startswith("#"):
        return piece
    return f" {PARAM_OPEN} {piece} {PARAM_CLOSE} "


def mark_spans(text: str, spans: list[tuple[int, int]]) -> str:
    """Each span's code wrapped line by line in PARAM_OPEN and PARAM_CLOSE, as a unit may start mid-block."""
    out, last = [], 0
    for start, end in spans:
        out += [text[last:start], "\n".join(_mark_line(p) for p in text[start:end].split("\n"))]
        last = end
    return "".join(out) + text[last:]


def unmark(text: str) -> str:
    """The text as written, param marks removed."""
    return text.replace(f" {PARAM_OPEN} ", "").replace(f" {PARAM_CLOSE} ", "")


def strip_param_marks(lines: list[str], width: int) -> tuple[list[str], set[int]]:
    """The unit's tokens without param marks, and the start of every shingle that reaches a param block's token."""
    kept: list[str] = []
    touching: set[int] = set()
    for line in lines:
        # Marks pair up within a line, so one a string folded away cannot leak past it.
        inside = False
        for tok in line.split():
            if tok in PARAM_MARKS:
                inside = tok == PARAM_OPEN
                continue
            if inside:
                touching.update(range(max(0, len(kept) - width + 1), len(kept) + 1))
            kept.append(tok)
    return kept, touching
