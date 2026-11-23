#!/usr/bin/env bash
# shared/contracts/think-split.json, replayed through a reference splitter: the file cannot ask a binding for an outcome D5 does not give.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${PREFLIGHT_PYTHON:-python3}" -I - "${1:-${TESTS_DIR}/../../../shared/contracts/think-split.json}" <<'PY'
import json
import pathlib
import sys

OPEN, CLOSE = "<think>", "</think>"
FIELDS = {"shown", "answer", "final", "thinking", "late_closes"}


def held(text):
    """How many characters at the end of text may still begin a tag."""
    for size in range(min(len(CLOSE) - 1, len(text)), 0, -1):
        if OPEN.startswith(text[-size:]) or CLOSE.startswith(text[-size:]):
            return size
    return 0


class Splitter:
    """OmniAccelerANT's ThinkingSplitter, which shows a late close as D5 asks, in Python."""

    def __init__(self):
        self.pending, self.inside, self.after_close = "", False, False
        self.answer, self.thinking, self.late_closes = "", 0, 0

    def settle(self, text, out):
        if self.inside:
            self.thinking += len(text)
            return
        text = text.lstrip() if self.after_close else text
        if text:
            self.after_close = False
            out.append(text)

    def push(self, piece):
        self.pending += piece
        out = []
        while True:
            tags = [CLOSE] if self.inside else [OPEN, CLOSE]
            found = sorted((self.pending.find(tag), tag) for tag in tags if tag in self.pending)
            if not found:
                safe = len(self.pending) - held(self.pending)
                self.settle(self.pending[:safe], out)
                self.pending = self.pending[safe:]
                self.answer += "".join(out)
                return "".join(out)
            at, tag = found[0]
            self.settle(self.pending[:at], out)
            self.pending = self.pending[at + len(tag):]
            if tag == CLOSE and not self.inside:
                self.late_closes += 1
                self.thinking += len(self.answer) + len("".join(out))
                self.answer, out = "", []
            self.thinking += len(tag)
            self.inside, self.after_close = tag == OPEN, tag == CLOSE

    def finish(self):
        out = []
        self.settle(self.pending, out)
        self.pending = ""
        self.answer += "".join(out)
        return "".join(out)


def final(text):
    """The lab's rule, cut at a block that opens after the last close and never closes (owner, 2026-11-23)."""
    if CLOSE in text:
        return text.rsplit(CLOSE, 1)[1].split(OPEN, 1)[0]
    return "" if OPEN in text else text


doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
cases = {case["name"]: case for case in doc["cases"]}
assert doc["schema_version"] == 1 and len(cases) == len(doc["cases"]), "version 1, and every name once"
for name, case in cases.items():
    pieces, expect = case["pieces"], case["expect"]
    assert pieces and all(isinstance(piece, str) for piece in pieces), f"{name}: pieces are strings"
    assert set(expect) == FIELDS, f"{name}: {sorted(expect)}"
    splitter = Splitter()
    shown = "".join(splitter.push(piece) for piece in pieces) + splitter.finish()
    got = {"shown": shown, "answer": splitter.answer, "final": final("".join(pieces)),
           "thinking": splitter.thinking, "late_closes": splitter.late_closes}
    assert got == expect, f"{name}: the reference splitter gives {got}"
print(f"think-split: {len(cases)} cases, each replayed through the reference splitter")
PY
