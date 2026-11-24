#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Hold each tracked page's prose at its census rows, which may only fall; a page without rows meets fixed limits.

Usage: verify_doc_prose.py [--root DIR] [--census FILE] [--write | --seed] [--report]
docs/code-quality-tooling.md#doc-prose-doc-prose
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path
from typing import TypeAlias

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_scope
from verify_comment_size import GENERATED, SKIP

HUB = Path(__file__).resolve().parents[2]
HUB_CENSUS = Path("docs/scripts/doc-prose.census")
CONSUMER_CENSUS = Path("doc-prose.census")
PATTERNS = ["*.md", "*.rst"]
METRICS = ("avg-sentence", "long-share", "ids-per-k", "bold-per-k")
WORDS = "words"
NEW_PAGE_LIMITS = {"avg-sentence": 22.0, "long-share": 15.0, "ids-per-k": 2.0}
AGENTS = "AGENTS.md"
AGENTS_TARGET = {True: 6000, False: 3000}
LONG_SENTENCE = 30
MIN_SENTENCE = 3
MIN_WORDS = 100
STYLE = "docs/writing-docs.md"
HEADER = "# <page> | <metric> | <value>: a value may only fall. verify_doc_prose.py --write lowers the rows."

# Records keep their dates on purpose, and a licence text is not ours to restyle.
EXEMPT = re.compile(r"changelog|backlog|archive|(^|/)decisions\.md$|(^|/)third_party/"
                    r"|(^|/)(licen[cs]e|copying|notice)[^/]*$|licen[cs]e-assets/|opensourcelicen[cs]es", re.IGNORECASE)
HTML_COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)
GENERATED_BLOCK = re.compile(r"<!--\s*generated:([\w.-]+):start\s*-->.*?<!--\s*generated:\1:end\s*-->", re.DOTALL)
FENCE = re.compile(r"^\s*(```|~~~)")
LIST_ITEM = re.compile(r"^\s*(?:[-*+]|\d+[.)]|#\.)\s+")
MD_SKIP = re.compile(r"^(?:\||#|\[[^\]]+\]:\s|(?:-{3,}|\*{3,}|_{3,}|={3,})$)")
UNDERLINE = re.compile(r"^([=\-~^\"'`#*+_:.])\1{2,}$")
SIMPLE_TABLE = re.compile(r"^=+(?:\s+=+)+$")
DIRECTIVE = re.compile(r"^\s*\.\.\s+([\w:-]+)::")
RST_SKIP = re.compile(r"^(?:\+[-=]|\||:[\w -]+:(?:\s|$))")
PROSE_DIRECTIVES = {"note", "warning", "tip", "important", "caution", "attention", "hint", "danger", "error",
                    "seealso", "admonition", "topic", "sidebar"}
MD_INLINE = (
    (re.compile(r"(`+)(?:(?!\1).)+?\1"), " X "),
    (re.compile(r"!\[[^\]]*\]\([^)]*\)"), " "),
    (re.compile(r"\[([^\]]*)\]\([^)]*\)"), r"\1"),
    (re.compile(r"\[([^\]]*)\]\[[^\]]*\]"), r"\1"),
    (re.compile(r"<https?://[^>]*>"), " X "),
    (re.compile(r"<[^>]+>"), " "),
)
RST_INLINE = (
    (re.compile(r"``.+?``"), " X "),
    (re.compile(r"(?::[\w:-]+:)?`([^`<]*?)\s*<[^`>]*>`_{0,2}"), r"\1"),
    (re.compile(r":[\w:-]+:`[^`]*`"), " X "),
    (re.compile(r"`([^`]*)`_{0,2}"), r"\1"),
    (re.compile(r"\|[\w -]+\|_{0,2}"), " X "),
)
ABBREVIATION = re.compile(r"\b(e\.g|i\.e|etc|vs|cf|approx|incl|resp)\.(?=\s)", re.IGNORECASE)
SENTENCE_END = re.compile(r"(?:(?<=[.!?])|(?<=[.!?][\"')\]*]))\s+(?=[\"'(\[*_A-Z0-9])")
DATE_OR_ID = re.compile(r"\b(?:20\d\d-[01]\d-[0-3]\d|D\d{1,2}|CON\d{1,4})\b")
BOLD = re.compile(r"\*\*(?=\S)[^*]+?(?<=\S)\*\*")

Metrics: TypeAlias = dict[str, float]
Census: TypeAlias = dict[tuple[str, str], float]


class CensusError(ValueError):
    """A census file the gate cannot read, or a write it must refuse."""


class Blocks:
    """Paragraphs and list items, one string each: a sentence never runs across two of them."""

    def __init__(self, inline: tuple[tuple[re.Pattern[str], str], ...]) -> None:
        self.inline = inline
        self.done: list[str] = []
        self.lines: list[str] = []

    def flush(self) -> None:
        if self.lines:
            self.done.append(" ".join(self.lines))
            self.lines = []

    def drop_title(self) -> None:
        """An underline under a one-line block makes that block a heading, not prose."""
        if len(self.lines) == 1:
            self.lines = []
        self.flush()

    def add(self, text: str) -> None:
        if LIST_ITEM.match(text):
            self.flush()
            text = LIST_ITEM.sub("", text, count=1)
        for pattern, repl in self.inline:
            text = pattern.sub(repl, text)
        if text.strip():
            self.lines.append(text.strip())


def _blank_out(match: re.Match[str]) -> str:
    """Removed text keeps its newlines, so the lines around it stay where they were."""
    return "\n" * match.group(0).count("\n")


def markdown_blocks(text: str) -> list[str]:
    """Prose blocks of a Markdown page: no fences, tables, headings, comments, link targets or generated blocks."""
    out = Blocks(MD_INLINE)
    fence = ""
    for line in HTML_COMMENT.sub(_blank_out, GENERATED_BLOCK.sub(_blank_out, text)).split("\n"):
        stripped = line.strip()
        if fence:
            fence = "" if stripped.startswith(fence) else fence
            continue
        opened = FENCE.match(line)
        quoted = stripped.lstrip("> ").strip()
        if opened:
            fence = opened.group(1)
            out.flush()
        elif re.fullmatch(r"=+|-+", quoted):
            out.drop_title()
        elif not quoted or MD_SKIP.match(quoted):
            out.flush()
        else:
            out.add(quoted)
    out.flush()
    return out.done


def _rst_structure(out: Blocks, line: str, stripped: str) -> int | None:
    """Handle a structural reST line; return the indent whose deeper lines to skip, -1 for done, None for prose."""
    indent = len(line) - len(line.lstrip())
    directive = DIRECTIVE.match(line)
    if directive or stripped.startswith(".."):
        out.flush()
        return -1 if directive and directive.group(1) in PROSE_DIRECTIVES else indent
    if UNDERLINE.match(stripped):
        out.drop_title()
        return -1
    if RST_SKIP.match(stripped):
        out.flush()
        return -1
    if stripped.endswith("::"):
        out.add(stripped[:-1])
        out.flush()
        return indent
    return None


def rst_blocks(text: str) -> list[str]:
    """Prose blocks of a reST page: no directives but admonitions, literal blocks, tables, titles or comments."""
    out = Blocks(RST_INLINE)
    skip_below: int | None = None
    table = False
    for line in text.split("\n"):
        stripped = line.strip()
        if skip_below is not None and (not stripped or len(line) - len(line.lstrip()) > skip_below):
            continue
        skip_below = None
        if table or SIMPLE_TABLE.match(stripped):
            table = bool(stripped)
            out.flush()
            continue
        if not stripped:
            out.flush()
            continue
        action = _rst_structure(out, line, stripped)
        if action is None:
            out.add(stripped)
        elif action >= 0:
            skip_below = action
    out.flush()
    return out.done


def sentence_lengths(block: str) -> list[int]:
    """Words per sentence; a fragment under MIN_SENTENCE words (a label, a lone path) is no sentence."""
    lengths = [len(part.split()) for part in SENTENCE_END.split(ABBREVIATION.sub(r"\1", block))]
    return [n for n in lengths if n >= MIN_SENTENCE]


def page_metrics(blocks: list[str]) -> Metrics | None:
    """The four rates of one page, or None when its prose is too short for a rate to mean anything."""
    text = " ".join(blocks)
    words = len(text.split())
    if words < MIN_WORDS:
        return None
    lengths = [n for block in blocks for n in sentence_lengths(block)]
    sentences = max(len(lengths), 1)
    per_k = 1000 / max(words, 1000)
    return {
        "avg-sentence": round(sum(lengths) / sentences, 1),
        "long-share": round(100 * sum(n > LONG_SENTENCE for n in lengths) / sentences, 1),
        "ids-per-k": round(len(DATE_OR_ID.findall(text)) * per_k, 1),
        "bold-per-k": round(len(BOLD.findall(text)) * per_k, 1),
    }


def graded_pages(root: Path) -> list[str]:
    """Tracked .md and .rst pages, minus records, licence texts, vendored and generated files."""
    pages = []
    for rel in gate_scope.tracked(str(root), PATTERNS):
        if EXEMPT.search(rel) or SKIP.search(rel):
            continue
        head = "\n".join((root / rel).read_text(encoding="utf-8", errors="replace").split("\n")[:5])
        if not GENERATED.search(head):
            pages.append(rel)
    return pages


def measure(root: Path) -> dict[str, Metrics]:
    """Every graded page's metrics, plus the root AGENTS.md word count."""
    measured: dict[str, Metrics] = {}
    for rel in graded_pages(root):
        text = (root / rel).read_text(encoding="utf-8", errors="replace")
        metrics = page_metrics(rst_blocks(text) if rel.endswith(".rst") else markdown_blocks(text))
        if metrics is not None:
            measured[rel] = metrics
    agents = root / AGENTS
    if agents.is_file():
        measured.setdefault(AGENTS, {})[WORDS] = float(len(agents.read_text(encoding="utf-8").split()))
    return measured


def load_census(path: Path) -> Census:
    """`<page> | <metric> | <value>` rows; a malformed or repeated row is an error, never a skip."""
    rows: Census = {}
    for num, raw in enumerate(path.read_text(encoding="utf-8").split("\n"), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) != 3 or parts[1] not in (*METRICS, WORDS) or not re.fullmatch(r"\d+(\.\d)?", parts[2]):
            raise CensusError(f"{path.name}:{num}: expected '<page> | <metric> | <value>', got {line!r}")
        if (parts[0], parts[1]) in rows:
            raise CensusError(f"{path.name}:{num}: a second {parts[1]} row for {parts[0]}; one of them is unread")
        rows[(parts[0], parts[1])] = float(parts[2])
    return rows


def render(rows: Census) -> str:
    order = {metric: i for i, metric in enumerate((*METRICS, WORDS))}
    lines = [HEADER]
    for (page, metric), value in sorted(rows.items(), key=lambda kv: (kv[0][0], order[kv[0][1]])):
        lines.append(f"{page} | {metric} | {int(value) if metric == WORDS else f'{value:.1f}'}")
    return "\n".join(lines) + "\n"


def lowered(census: Census, measured: dict[str, Metrics]) -> Census:
    """The census with each row moved down to its measurement; rows of pages no longer graded go."""
    return {key: min(was, measured[key[0]][key[1]]) for key, was in census.items()
            if key[1] in measured.get(key[0], {})}


def ratchet(page: str, values: Metrics, census: Census) -> list[str]:
    problems = []
    for metric, now in values.items():
        was = census.get((page, metric))
        if was is None:
            problems.append(f"{page}: no {metric} row; a page in the census needs a row for each metric")
        elif now > was:
            problems.append(f"{page}: {metric} grew from {was:g} to {now:g}; rewrite the new text ({STYLE})")
        elif now < was:
            problems.append(f"{page}: {metric} fell from {was:g} to {now:g}; lower its row in this commit (--write)")
    return problems


def limits(page: str, values: Metrics, hub: bool) -> list[str]:
    caps = {**NEW_PAGE_LIMITS, WORDS: float(AGENTS_TARGET[hub])}
    return [f"{page}: {metric} is {now:g}, over the {caps[metric]:g} a page without census rows may have ({STYLE})"
            for metric, now in values.items() if metric in caps and now > caps[metric]]


def grade(measured: dict[str, Metrics], census: Census, hub: bool) -> list[str]:
    """Pages with rows ride the ratchet, pages without meet the fixed limits, and rows nothing measures fail."""
    known = {page for page, _metric in census}
    stale = sorted({page for page, metric in census if metric not in measured.get(page, {})})
    problems = [f"{page}: census rows nothing measures (gone, exempt or under {MIN_WORDS} words); --write deletes them"
                for page in stale]
    for page, values in sorted(measured.items()):
        problems += ratchet(page, values, census) if page in known else limits(page, values, hub)
    return problems


def agents_line(measured: dict[str, Metrics], hub: bool) -> str:
    if WORDS not in measured.get(AGENTS, {}):
        return f"no {AGENTS}"
    words = int(measured[AGENTS][WORDS])
    target = AGENTS_TARGET[hub]
    gap = f"{words - target} to go" if words > target else "within it"
    return f"{AGENTS}: {words} words, target {target}, {gap}"


def report(measured: dict[str, Metrics], census: Census) -> None:
    pages = sorted((p for p in measured if "avg-sentence" in measured[p]), key=lambda p: -measured[p]["avg-sentence"])
    print(f"{'page':60} {'avg':>5} {'long%':>6} {'ids/k':>6} {'bold/k':>6}  census")
    for page in pages:
        m = measured[page]
        rows = "rows" if any(key[0] == page for key in census) else "limits"
        print(f"{page:60} {m['avg-sentence']:5.1f} {m['long-share']:6.1f} {m['ids-per-k']:6.1f} {m['bold-per-k']:6.1f}  {rows}")


def run(root: Path, census_path: Path, hub: bool, args: argparse.Namespace) -> int:
    measured = measure(root)
    if args.seed:
        if census_path.exists():
            raise CensusError(f"{census_path} exists; --seed writes a first census only, --write lowers this one")
        census_path.write_text(render({(p, m): v for p, values in measured.items() for m, v in values.items()}), encoding="utf-8")
        print(f"doc-prose: seeded {census_path} with {len(measured)} page(s)")
    if not census_path.exists():
        if hub:
            raise CensusError(f"{census_path} is missing; the hub grades its pages against it")
        print(f"doc-prose: OFF for {root} until {census_path.name} exists; --seed writes it. "
              f"{len(measured)} page(s) measured. {agents_line(measured, hub)}")
        if args.report:
            report(measured, {})
        return 0
    census = load_census(census_path)
    if args.write:
        census = lowered(census, measured)
        census_path.write_text(render(census), encoding="utf-8")
    if args.report:
        report(measured, census)
    problems = grade(measured, census, hub)
    print(f"doc-prose: {len(measured)} page(s), {len({p for p, _m in census})} with census rows. {agents_line(measured, hub)}")
    for problem in problems:
        print(f"FAIL: {problem}", file=sys.stderr)
    return 1 if problems else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    parser.add_argument("--root", help="the repository to grade (default: this hub)")
    parser.add_argument("--census", type=Path, help="the census file (default: docs/scripts/doc-prose.census in the hub, "
                                                    "<root>/doc-prose.census in a consumer)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--write", action="store_true", help="lower each row to its measurement; never raises or adds one")
    mode.add_argument("--seed", action="store_true", help="write a first census from today's values")
    parser.add_argument("--report", action="store_true", help="list every page's metrics, longest sentences first")
    args = parser.parse_args(argv)
    try:
        root = Path(gate_scope.resolve_root(args.root, str(HUB)))
        hub = gate_scope.is_hub(str(root), str(HUB))
        census_path = args.census or root / (HUB_CENSUS if hub else CONSUMER_CENSUS)
        return run(root, census_path, hub, args)
    except gate_scope.ScopeError as exc:
        return gate_scope.die(exc)
    except (CensusError, OSError) as exc:
        print(f"ERROR: doc-prose: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
