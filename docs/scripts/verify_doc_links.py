#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""verify_doc_links.py -- the docs cross-reference gate.

Why this exists
---------------
The 2026-08-25 structural pass moved ~5,000 lines between pages and rewrote ~50
cross-references by hand. It was verified once, with throwaway scripts, and then
nothing kept it verified. This repo's own history says that is not enough: the
Dev Drive incident recorded at the top of ``docs/INDEX.md`` is three copies of
one command drifting apart because nothing was watching.

So this checks the four ways a docs tree rots, all of them silent:

1. **link**    a relative Markdown link whose target file no longer exists.
2. **anchor**  a ``file.md#heading`` deep link whose heading was renamed.
3. **section** the repo's own ``file.md`` + U+00A7 + ``Heading`` prose
               convention. These are the ones that rot hardest, because they
               are plain text -- nothing renders them, so nothing complains.
4. **index**   a page reachable from neither ``docs/INDEX.md`` nor the Sphinx
               toctree in ``docs/index.rst``. That is how ``build-cache-tiers.md``
               (24 KB) became invisible: present, maintained, linked by nobody.

No network, no imports of project code, no build -- safe for hooks and CI.

Usage:  python3 docs/scripts/verify_doc_links.py [--quiet]
Exit:   0 = clean, 1 = findings, 2 = usage/tree error.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DOCS = REPO_ROOT / "docs"
SECTION_SIGN = "§"

# Root-level Markdown that participates in the cross-reference graph.
ROOT_DOCS = ("README.md", "AGENTS.md", "CHANGELOG.md")

# History is exempt from the anchor and section-ref checks. Archives and the
# changelog are dated records of what was true on the day; a heading renamed
# afterwards must not force an edit to the record, and rewriting them to keep a
# gate quiet would falsify it. Their *links* are still checked for file
# existence, because a moved page breaks those for a reader too.
ARCHIVE_MARKERS = ("archive",)
HISTORY_FILES = ("CHANGELOG.md",)

MD_LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*$", re.MULTILINE)
HTML_ANCHOR = re.compile(r'<a\s+id="([^"]+)"')
FENCE = re.compile(r"^\s*(```|~~~)")
# "windows-build-lanes.md § Store GC" / "`docs/failure-modes.md` § Some Heading"
SECTION_REF = re.compile(
    r"([A-Za-z0-9._/-]+\.md)`?\s*(?:\]\([^)]*\))?\s*"
    + SECTION_SIGN
    # Stop at [ and ] as well as sentence punctuation: without them a Markdown
    # link whose TEXT half carries the reference ("[`x.md` REF Name](x.md#a)")
    # has its trailing "](x.md" read as part of the section name.
    + r"\s*\"?([^.,;)|\"\[\]\n]{2,70})"
)


def slug(heading: str) -> str:
    """GitHub's heading -> anchor transform, closely enough for our headings."""
    text = heading.replace("`", "")
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)  # [label](url) -> label
    text = text.lower()
    text = re.sub(r"[^a-z0-9 _\-]", "", text)
    return text.replace(" ", "-")


def strip_fenced(text: str) -> str:
    """Blank out fenced code blocks so shell comments are not read as headings."""
    out, in_fence, marker = [], False, ""
    for line in text.split("\n"):
        hit = FENCE.match(line)
        if hit and not in_fence:
            in_fence, marker = True, hit.group(1)
            out.append("")
            continue
        if in_fence:
            if line.lstrip().startswith(marker):
                in_fence = False
            out.append("")
            continue
        out.append(line)
    return "\n".join(out)


class Doc:
    __slots__ = ("path", "rel", "raw", "body", "anchors", "headings", "is_archive")

    def __init__(self, path: Path) -> None:
        self.path = path
        self.rel = path.relative_to(REPO_ROOT).as_posix()
        self.raw = path.read_text(encoding="utf-8")
        self.body = strip_fenced(self.raw)
        self.headings = [m.group(2) for m in HEADING.finditer(self.body)]
        self.anchors = {slug(h) for h in self.headings}
        self.anchors |= set(HTML_ANCHOR.findall(self.raw))
        self.is_archive = (
            any(m in path.name for m in ARCHIVE_MARKERS) or path.name in HISTORY_FILES
        )


def collect() -> dict[str, Doc]:
    paths = [REPO_ROOT / n for n in ROOT_DOCS]
    paths += sorted(DOCS.rglob("*.md"))
    docs: dict[str, Doc] = {}
    for p in paths:
        if not p.is_file() or "_build" in p.parts or ".venv" in p.parts:
            continue
        d = Doc(p)
        docs[d.rel] = d
    return docs


def check_links_and_anchors(docs: dict[str, Doc], findings: list[str]) -> tuple[int, int]:
    links = anchors = 0
    for doc in docs.values():
        for m in MD_LINK.finditer(doc.raw):
            url = m.group(1)
            if url.startswith(("http://", "https://", "mailto:")):
                continue
            target, _, anchor = url.partition("#")
            if target:
                resolved = (doc.path.parent / target).resolve()
                links += 1
                if not resolved.exists():
                    findings.append(f"[link]    {doc.rel} -> {url}  (no such file)")
                    continue
            else:
                resolved = doc.path
            if not anchor or doc.is_archive:
                continue
            try:
                key = resolved.relative_to(REPO_ROOT).as_posix()
            except ValueError:
                continue
            other = docs.get(key)
            if other is None:  # non-Markdown target (e.g. a .yml) -- nothing to check
                continue
            anchors += 1
            if anchor not in other.anchors:
                findings.append(f"[anchor]  {doc.rel} -> {url}  (no such heading)")
    return links, anchors


NUM_PREFIX = re.compile(r"^\d+(?:-\d+)*-")


def _lead(anchor: str, n: int = 2) -> str:
    """First n hyphen-separated words of a slug -- the stable part of a name."""
    return "-".join([w for w in anchor.split("-") if w][:n])


def _forms(anchor: str) -> tuple[str, ...]:
    """An anchor plus the variants prose actually cites it by.

    Numbered headings ("## 4. S3 -- per-stage registry cache refs") get cited
    by their label alone, so the leading ordinal has to come off before the
    comparison.
    """
    stripped = NUM_PREFIX.sub("", anchor)
    return (anchor, stripped) if stripped != anchor else (anchor,)


def _heading_match(want: str, anchors: set[str]) -> bool:
    """True if `want` plausibly names one of `anchors`.

    Prose abbreviates a heading, runs past it, and sometimes cites only the
    identifier in its parentheses ("(#120 step 2)"). Exact equality is
    therefore useless. Accept a prefix or a suffix in either direction, or --
    for multi-word names -- agreement on the first two words. That is still
    strict enough to fail loudly when a heading is renamed or its page is
    split, which is the rot this exists to catch.
    """
    for raw in anchors:
        for a in _forms(raw):
            if not a:
                continue
            if a.startswith(want) or want.startswith(a):
                return True
            if len(want.split("-")) >= 2 and a.endswith(want):
                return True
            if len(want.split("-")) >= 2 and _lead(a) == _lead(want):
                return True
    return False


def check_section_refs(docs: dict[str, Doc], findings: list[str]) -> int:
    checked = 0
    for doc in docs.values():
        if doc.is_archive:
            continue
        for m in SECTION_REF.finditer(doc.body):
            target_name, raw_name = m.group(1), m.group(2).strip().rstrip("*_`")
            key = next(
                (k for k in docs if k == target_name or k.endswith("/" + Path(target_name).name)),
                None,
            )
            if key is None:
                continue  # file existence is the [link] check's job
            other = docs[key]
            if other.is_archive:
                continue
            want = slug(raw_name)
            if not want:
                continue
            checked += 1
            # Prose abbreviates: "§ Build Commands for the full sequence" points
            # at the heading "Build Commands". Accept either as a prefix of the
            # other, so a rename still fails but prose stays natural.
            if _heading_match(want, other.anchors):
                continue
            findings.append(
                f"[section] {doc.rel} -> {target_name} {SECTION_SIGN} {raw_name}  (no such heading)"
            )
    return checked


def check_index_coverage(docs: dict[str, Doc], findings: list[str]) -> int:
    index_rst = DOCS / "index.rst"
    index_md = DOCS / "INDEX.md"
    if not index_rst.is_file() or not index_md.is_file():
        findings.append("[index]   docs/index.rst or docs/INDEX.md is missing")
        return 0
    toctree = {
        line.strip()
        for line in index_rst.read_text(encoding="utf-8").split("\n")
        if line.startswith("   ") and line.strip() and not line.strip().startswith(":")
    }
    index_text = index_md.read_text(encoding="utf-8")
    checked = 0
    for rel, doc in sorted(docs.items()):
        if not rel.startswith("docs/") or doc.path.name == "INDEX.md":
            continue
        stem = doc.path.relative_to(DOCS).with_suffix("").as_posix()
        checked += 1
        if stem not in toctree:
            findings.append(f"[index]   {rel} is in no docs/index.rst toctree")
        if doc.path.name not in index_text:
            findings.append(f"[index]   {rel} is linked from no row in docs/INDEX.md")
    return checked


def main() -> int:
    ap = argparse.ArgumentParser(description="Verify docs cross-references.")
    ap.add_argument("--quiet", action="store_true", help="only print on failure")
    args = ap.parse_args()

    if not DOCS.is_dir():
        print("ERROR: docs/ not found -- run from the repo (or fix REPO_ROOT)", file=sys.stderr)
        return 2

    docs = collect()
    if not docs:
        print("ERROR: no Markdown found to check", file=sys.stderr)
        return 2

    findings: list[str] = []
    n_links, n_anchors = check_links_and_anchors(docs, findings)
    n_sections = check_section_refs(docs, findings)
    n_pages = check_index_coverage(docs, findings)

    if findings:
        print(f"docs cross-reference gate: {len(findings)} finding(s)\n", file=sys.stderr)
        for f in findings:
            print("  " + f, file=sys.stderr)
        print(
            "\nFix the reference, or -- if a page genuinely moved -- update "
            "docs/INDEX.md and docs/index.rst too.",
            file=sys.stderr,
        )
        return 1

    if not args.quiet:
        print(
            f"docs cross-reference gate OK: {len(docs)} pages, {n_links} links, "
            f"{n_anchors} anchors, {n_sections} {SECTION_SIGN}-refs, "
            f"{n_pages} pages index-covered."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
