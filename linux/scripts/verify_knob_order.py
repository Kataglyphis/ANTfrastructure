#!/usr/bin/env python3
"""Fail on a bare read of a knob where its in-file `${X:=...}` default has not run on every path, following call order.

Sees one file: sourced definitions, cross-file callers and subshell scope are not modelled. docs/code-quality-tooling.md#knob-default-order-knob-order"""
import argparse
import os
import re
import sys
from collections.abc import Iterable, Iterator, Sequence
from dataclasses import dataclass, field

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_scope
from verify_code_size import DEF, ROOT, code_lines, subjects

SCAN = ("linux/scripts",)
SKIP_PART = "/tests/"
NAME = r"[A-Za-z_][A-Za-z0-9_]*"
DEFAULT = re.compile(r"\$\{(" + NAME + r"):?=")
READ = re.compile(r"\$\{(" + NAME + r")(?:\[[^]]*\])?(?P<op>[^}]{0,2})|\$(" + NAME + r")")
GUARDED = (":-", ":+", ":=", ":?", "-", "+", "=", "?")
EMPTY_TEST = re.compile(r"-[nz]\s+\"?\$\{(" + NAME + r"):-\}")
ASSIGN = re.compile(r"^(" + NAME + r")\+?=")
LISTS = re.compile(r"^(local|declare|typeset|export|readonly)\s+(.*)$")
READER = re.compile(r"^(?:IFS=\S*\s+)?(?:read|mapfile|readarray)\s+(.*)$")
FOR = re.compile(r"^for\s+(" + NAME + r")\b")
PRINTF_V = re.compile(r"^printf\s+-v\s+(" + NAME + r")")
KEYWORDS = ("if", "elif", "while", "until", "then", "do", "else", "!", "time", "{", "(")
OPENERS = {"if": "if", "case": "case", "while": "loop", "until": "loop", "for": "loop", "select": "loop"}
ENDINGS = ("fi", "done", "esac")
ABORTS = ("exit", "die", "err", "fail", "return")
CONTINUED = ("\\", "&&", "||", "|")
SPLIT = re.compile(r"(;;&?|;&|&&|\|\||;|\|)")
ENV_PREFIX = re.compile(r"^(?:" + NAME + r"=\S*\s+)+")
SUBST_CALL = re.compile(r"\$\(\s*(" + NAME + r")\b")
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*")
CASE_ARM = re.compile(r"^\(?([^()]*)\)(.*)$")


def expanding_text(raw: str) -> str:
    """One line without single-quoted spans or a trailing comment; double-quoted text stays, since it expands."""
    out, i, double = [], 0, False
    while i < len(raw):
        c = raw[i]
        if c == "\\":
            i += 2
            continue
        if c == "'" and not double:
            end = raw.find("'", i + 1)
            i = len(raw) if end < 0 else end + 1
            continue
        if c == "#" and not double and (i == 0 or raw[i - 1] in " \t;"):
            break
        double = double != (c == '"')
        out.append(c)
        i += 1
    return "".join(out)


def mask_substitutions(code: str) -> str:
    """Blank `$(...)` bodies, whose separators belong to a child shell rather than this statement."""
    out, depth, i = [], 0, 0
    while i < len(code):
        if code.startswith("$(", i):
            depth += 1
            i += 2
            continue
        c = code[i]
        if depth == 0:
            out.append(c)
        else:
            depth += (c == "(") - (c == ")")
        i += 1
    return "".join(out)


@dataclass
class Stmt:
    """A logical line: the code view for structure, the expanding view for reads, its 1-based number."""
    code: str
    live: str
    line: int


def logical(code: Sequence[str], live: Sequence[str], first: int) -> list[Stmt]:
    """Join continuations; `first` is the 1-based number of code[0]."""
    out: list[Stmt] = []
    pending: list[tuple[str, str]] = []
    start = first
    for number, (c, l) in enumerate(zip(code, live), start=first):
        if not c.strip():
            continue
        start = start if pending else number
        pending.append((c.strip().rstrip("\\"), l.strip().rstrip("\\")))
        if not c.rstrip().endswith(CONTINUED):
            out.append(Stmt(" ".join(p[0] for p in pending), " ".join(p[1] for p in pending), start))
            pending = []
    if pending:
        out.append(Stmt(" ".join(p[0] for p in pending), " ".join(p[1] for p in pending), start))
    return out


def function_spans(code: Sequence[str]) -> Iterator[tuple[str, int, int]]:
    """(name, first index, last index) of each column-0 function, braces counted over the code view."""
    i = 0
    while i < len(code):
        m = DEF.match(code[i])
        depth, end = 0, i
        for end in range(i, len(code) if m else i):
            depth += code[end].count("{") - code[end].count("}")
            if depth <= 0:
                break
        if m:
            yield m.group(1) or m.group(2), i, end
        i = end + 1


@dataclass
class Parsed:
    """One file's walk inputs: knob -> first default line, top-level statements, function bodies."""
    knobs: dict[str, int]
    top: list[Stmt]
    bodies: dict[str, list[Stmt]]


def strip_wrapper(text: str, tail_only: bool = False) -> str:
    """A function's first or last line without its head or closing brace."""
    if tail_only:
        return text[:text.rfind("}")] if "}" in text else text
    return text[text.index("{") + 1:] if "{" in text else text


def parse(lines: Sequence[str]) -> Parsed:
    """Split a file into top-level statements and function bodies, and list its defaulted knobs."""
    code = code_lines(lines)
    live = [expanding_text(raw) if seen.strip() else "" for raw, seen in zip(lines, code)]
    bodies: dict[str, list[Stmt]] = {}
    top_code, top_live = list(code), list(live)
    for name, i, j in function_spans(code):
        body_code, body_live = code[i:j + 1], live[i:j + 1]
        body_code[0], body_live[0] = strip_wrapper(body_code[0]), strip_wrapper(body_live[0])
        body_code[-1], body_live[-1] = strip_wrapper(body_code[-1], True), strip_wrapper(body_live[-1], True)
        bodies[name] = logical(body_code, body_live, i + 1)
        top_code[i:j + 1] = [""] * (j + 1 - i)
        top_live[i:j + 1] = [""] * (j + 1 - i)
    knobs: dict[str, int] = {}
    for number, text in enumerate(live, start=1):
        for m in DEFAULT.finditer(text):
            knobs.setdefault(m.group(1), number)
    return Parsed(knobs, logical(top_code, top_live, 1), bodies)


def default_names(live: str) -> set[str]:
    """Names a text gives a `${X:=...}` default."""
    return {m.group(1) for m in DEFAULT.finditer(live)}


def bare_reads(live: str) -> Iterable[str]:
    """Names a text expands in a form that aborts under `set -u` when unset."""
    for m in READ.finditer(live):
        if m.group(3):
            yield m.group(3)
        elif not m.group("op").startswith(GUARDED):
            yield m.group(1)


def binds(piece: str) -> set[str]:
    """Names one simple command binds; `export X` alone binds nothing."""
    for pattern in (ASSIGN, FOR, PRINTF_V):
        m = pattern.match(piece)
        if m:
            return {m.group(1)}
    m = LISTS.match(piece)
    if m:
        words = [w for w in m.group(2).split() if re.fullmatch(NAME + r"(\+?=.*)?", w)]
        keep = m.group(1) not in ("export", "readonly")
        return {re.split(r"\+?=", w)[0] for w in words if keep or "=" in w}
    m = READER.match(piece)
    return {w for w in m.group(1).split() if re.fullmatch(NAME, w)} if m else set()


def command_word(piece: str) -> str:
    """The command word of a simple command, past keywords and environment prefixes."""
    words = ENV_PREFIX.sub("", piece).split()
    while words and words[0] in KEYWORDS:
        words.pop(0)
    return words[0] if words else ""


@dataclass
class Frame:
    """An open compound command: what held on entry and what each finished arm left defined."""
    kind: str
    entry: set[str]
    arms: list[set[str]] = field(default_factory=list)
    complete: bool = False
    dead: bool = False

    def finish_arm(self, defined: set[str]) -> None:
        """Record the running arm; an arm that left the function or script constrains nothing after it."""
        if not self.dead:
            self.arms.append(set(defined))
        self.dead = False

    def merged(self) -> set[str]:
        """What holds after the compound: the entry, plus what every arm of a complete one defined."""
        return set.intersection(*self.arms) | self.entry if self.complete and self.arms else set(self.entry)


class Flow:
    """Must-defined names through one statement list."""

    def __init__(self, walker: "Walker", defined: set[str], where: str) -> None:
        self.walker = walker
        self.defined = defined
        self.where = where
        self.frames: list[Frame] = []
        self.returned: list[set[str]] = []
        self.tested: set[str] = set()
        self.own: set[str] = set()

    def run(self, stmts: Sequence[Stmt]) -> set[str]:
        for stmt in stmts:
            self.statement(stmt)
        return self.defined.intersection(*self.returned) if self.returned else self.defined

    def statement(self, stmt: Stmt) -> None:
        self.tested.update(EMPTY_TEST.findall(stmt.live))
        self.walker.note_reads(stmt, self.defined | self.tested, self.where)
        for m in SUBST_CALL.finditer(stmt.code):
            self.walker.visit(m.group(1), self.defined)
        pieces = SPLIT.split(mask_substitutions(stmt.code))
        spoken = SPLIT.split(mask_substitutions(stmt.live))
        aligned = len(spoken) == len(pieces)
        piped = "|" in pieces
        conditional = piped
        for index, piece in enumerate(pieces):
            self.own = default_names(spoken[index]) if aligned else set()
            conditional = self.piece(piece, conditional, piped)
        if not aligned and not conditional:
            self.defined = self.defined | default_names(stmt.live)

    def piece(self, piece: str, conditional: bool, piped: bool) -> bool:
        if piece in ("&&", "||"):
            return True
        if piece == ";":
            return piped
        if piece in (";;", ";&", ";;&"):
            self.end_case_arm()
            return piped
        if piece != "|" and piece.strip():
            self.simple(piece.strip(), conditional)
        return conditional

    def end_case_arm(self) -> None:
        if self.frames and self.frames[-1].kind == "case":
            self.frames[-1].finish_arm(self.defined)
            self.frames[-1].dead = True
            self.defined = set(self.frames[-1].entry)

    def simple(self, text: str, conditional: bool) -> None:
        head = text.split()[0]
        if head in OPENERS:
            self.frames.append(Frame(OPENERS[head], set(self.defined)))
            self.defined = self.defined | binds(text) if head == "for" else self.defined
            self.command(text[len(head):].strip(), True)
        elif head in ("elif", "else"):
            self.next_arm(head)
            self.command(text[len(head):].strip(), True)
        elif head in ENDINGS or (head == "}" and self.frames and self.frames[-1].kind == "group"):
            self.close()
        elif conditional and text.split()[-1] == "{":
            self.frames.append(Frame("group", set(self.defined)))
        else:
            self.command(self.past_case_pattern(text), conditional)

    def past_case_pattern(self, text: str) -> str:
        """Strip a case arm's pattern, noting the `*)` that makes the case complete."""
        m = CASE_ARM.match(text)
        if not m or not self.frames or self.frames[-1].kind != "case":
            return text
        self.frames[-1].complete = self.frames[-1].complete or m.group(1).strip() == "*"
        self.frames[-1].dead = False
        return m.group(2).strip()

    def next_arm(self, head: str) -> None:
        if self.frames:
            frame = self.frames[-1]
            frame.finish_arm(self.defined)
            frame.complete = head == "else"
            self.defined = set(frame.entry)

    def close(self) -> None:
        if self.frames:
            frame = self.frames.pop()
            frame.finish_arm(self.defined)
            self.defined = frame.merged()

    def command(self, text: str, conditional: bool) -> None:
        head = command_word(text)
        if head in ABORTS and self.frames:
            self.frames[-1].dead = True
        if head == "return" and text.split()[-1] in ("return", "0"):
            self.returned.append(set(self.defined))
        must = not conditional
        added = self.walker.visit(head, self.defined)
        for word in WORD.findall(text):
            if word != head:
                self.walker.visit(word, self.defined)
        if must:
            self.defined = self.defined | added | self.own | binds(ENV_PREFIX.sub("", text) or text)


class Walker:
    """Abstract execution of one file, top level first, then every function nothing here calls."""

    def __init__(self, parsed: Parsed) -> None:
        self.p = parsed
        self.found: dict[tuple[int, str], str] = {}
        self.visited: set[str] = set()
        self.memo: dict[tuple[str, frozenset[str]], set[str]] = {}
        self.stack: list[str] = []

    def run(self) -> dict[tuple[int, str], str]:
        flow = Flow(self, set(), "top level")
        for stmt in self.p.top:
            flow.statement(stmt)
        for name in sorted(self.p.bodies, key=self.mentioned):
            if name not in self.visited:
                self.visit(name, flow.defined)
        return self.found

    def mentioned(self, name: str) -> bool:
        """Whether another function names `name`: a library's real entries walk first, helpers under their callers."""
        return any(name in WORD.findall(stmt.code) for other, body in self.p.bodies.items() if other != name for stmt in body)

    def visit(self, name: str, defined: set[str]) -> set[str]:
        """Walk function `name` under `defined`; what it adds on every path that returns."""
        if name not in self.p.bodies or name in self.stack:
            return set()
        self.visited.add(name)
        key = (name, frozenset(defined & set(self.p.knobs)))
        if key not in self.memo:
            self.stack.append(name)
            self.memo[key] = Flow(self, set(defined), name).run(self.p.bodies[name]) - defined
            self.stack.pop()
        return self.memo[key]

    def note_reads(self, stmt: Stmt, defined: set[str], where: str) -> None:
        for name in bare_reads(stmt.live):
            if name in self.p.knobs and name not in defined | default_names(stmt.live):
                self.found.setdefault((stmt.line, name), where)


def findings(rel: str, lines: Sequence[str]) -> list[str]:
    """One row per read that can run before its default."""
    parsed = parse(lines)
    if not parsed.knobs:
        return []
    return [f"{rel}:{line}: {name} read in {where} before its default at line {parsed.knobs[name]} ran on every path"
            for (line, name), where in sorted(Walker(parsed).run().items())]


def scan(root: str) -> list[str]:
    out: list[str] = []
    tops = SCAN if gate_scope.is_hub(root, ROOT) else None
    for path, rel in subjects(root, lambda fn: fn.endswith(".sh"), tops):
        if SKIP_PART not in "/" + rel:
            with open(path, encoding="utf-8", errors="replace") as fh:
                out.extend(findings(rel, fh.read().splitlines()))
    return out


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=None)
    args = parser.parse_args(argv)
    try:
        root = gate_scope.resolve_root(args.root, ROOT)
    except gate_scope.ScopeError as exc:
        print(f"knob-order: {exc}", file=sys.stderr)
        return 2
    found = scan(root)
    print("\n".join(found) if found else "knob-order: every defaulted knob runs before its reads")
    if found:
        print(f"knob-order: {len(found)} read(s) can run before their default; move the default above the first reader.", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
