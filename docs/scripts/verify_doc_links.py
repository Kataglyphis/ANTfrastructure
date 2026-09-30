#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""Docs cross-reference gate: links, anchors, section refs, index coverage, code and header pointers (docs/code-quality-tooling.md#code-to-docs-pointers-doc-links)."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

# HUB_ROOT is where the gate lives, REPO_ROOT the tree it grades (--root): docs/code-quality-tooling.md#the-scan-root-contract
HUB_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = HUB_ROOT
DOCS = REPO_ROOT / "docs"
SECTION_SIGN = "§"

# Root-level Markdown that participates in the cross-reference graph.
ROOT_DOCS = ("README.md", "AGENTS.md", "CHANGELOG.md")

# Dated records skip the anchor and section checks (rewriting them would falsify them); their links are still checked.
ARCHIVE_MARKERS = ("archive",)
HISTORY_FILES = ("CHANGELOG.md",)

# Code trees whose docs/ pointers are checked. windows/ is its own lane.
CODE_SCAN = ("linux", "docs/scripts", ".github", "Makefile")
# The header rule's scope: a leading comment block in a shell or Python file.
HEADER_LINES = 10
HEADER_SUFFIXES = (".sh", ".py")
HEADER_ALLOW = Path(__file__).with_name("doc-header-pointers.allow")
# Pages no header may name, frozen or not: an open backlog entry is archived the day it closes.
UNFREEZABLE_PAGES = ("refactoring-backlog.md",)
CODE_SKIP_SUFFIXES = (".md", ".patch", ".diff")
CODE_SKIP_PARTS = {"_build", ".venv", "__pycache__", ".pytest_cache", "node_modules"}
# Output trees skipped even where git cannot answer (the mutation gate's mirror has no .git); test-doc-links.sh pins the list.
UNTRACKED_OUTPUT = (
    # Gitignored but still on disk, the shape this floor exists for.
    "linux/webserver/dist",
    "linux/llm-stack/.env",
    "linux/llm-stack/ollama-binary.tar.zst",
)


def _ignored_paths(paths: list) -> set:
    """Paths git ignores (output, not source) plus the UNTRACKED_OUTPUT floor, which also covers tracked output and a git-free mirror."""
    if not paths:
        return set()
    try:
        proc = subprocess.run(
            ["git", "check-ignore", "--stdin"],
            input="\n".join(str(p) for p in paths),
            capture_output=True, text=True, cwd=REPO_ROOT, timeout=60,
        )
    except Exception:
        return _static_ignores(paths)
    if proc.returncode not in (0, 1):
        # 0 = some ignored, 1 = none; anything else means git could not answer.
        return _static_ignores(paths)
    asked = {line.strip() for line in proc.stdout.splitlines() if line.strip()}
    return asked | _static_ignores(paths)


def _static_ignores(paths: list) -> set:
    """The git-free floor, matched on path boundaries so ".env" cannot swallow ".env.example"."""
    out = set()
    for p in paths:
        s = str(p)
        posix = s.replace("\\", "/")  # a Windows path, matched against the POSIX entries
        for entry in UNTRACKED_OUTPUT:
            if posix == entry or posix.startswith(entry + "/"):
                out.add(s)
                break
    return out
CODE_POINTER = re.compile(
    r"(?<![\w/.-])((?:\.\./)*docs/[A-Za-z0-9._/-]+\.md)(?:#([A-Za-z0-9_-]+))?"
)

sys.path.insert(0, str(HUB_ROOT / "linux" / "scripts"))
from quality_allow import load_keys  # noqa: E402
import gate_scope  # noqa: E402

MD_LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*$", re.MULTILINE)
HTML_ANCHOR = re.compile(r'<a\s+id="([^"]+)"')
FENCE = re.compile(r"^\s*(```|~~~)")
# "windows-build-lanes.md § Store GC" / "`docs/failure-modes.md` § Some Heading"
SECTION_REF = re.compile(
    r"([A-Za-z0-9._/-]+\.md)`?\s*(?:\]\([^)]*\))?\s*"
    + SECTION_SIGN
    # Stop at [ and ] too, or a link whose text carries the reference reads "](x.md" into the name.
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


def _is_hub() -> bool:
    return gate_scope.is_hub(str(REPO_ROOT), str(HUB_ROOT))


def collect() -> dict[str, Doc]:
    """The hub's curated page set, or under --root every tracked page."""
    if _is_hub():
        paths = [REPO_ROOT / n for n in ROOT_DOCS]
        paths += sorted(DOCS.rglob("*.md"))
    else:
        paths = [REPO_ROOT / rel
                 for rel in gate_scope.tracked(str(REPO_ROOT), ["*.md", "*.rst"])
                 if rel.endswith(".md")]
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
    """An anchor plus the variants prose cites it by: numbered headings lose their leading ordinal."""
    stripped = NUM_PREFIX.sub("", anchor)
    return (anchor, stripped) if stripped != anchor else (anchor,)


def _heading_match(want: str, anchors: set[str]) -> bool:
    """True if `want` plausibly names one of `anchors`: a prefix or suffix either way, or the same first two words."""
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
            # Prose abbreviates, so either may be a prefix of the other; a rename still fails.
            if _heading_match(want, other.anchors):
                continue
            findings.append(
                f"[section] {doc.rel} -> {target_name} {SECTION_SIGN} {raw_name}  (no such heading)"
            )
    return checked


def code_files() -> list[Path]:
    out: list[Path] = []
    if not _is_hub():
        # A consumer has no CODE_SCAN layout, and assuming one would silently grade nothing.
        return [REPO_ROOT / rel
                for rel in gate_scope.tracked(str(REPO_ROOT), ["*"])
                if not rel.endswith(CODE_SKIP_SUFFIXES)
                and not (CODE_SKIP_PARTS & set(Path(rel).parts))]
    for name in CODE_SCAN:
        root = REPO_ROOT / name
        if root.is_file():
            out.append(root)
            continue
        if not root.is_dir():
            continue
        for f in sorted(root.rglob("*")):
            if f.is_file() and f.suffix not in CODE_SKIP_SUFFIXES and not (
                CODE_SKIP_PARTS & set(f.parts)
            ):
                out.append(f)
    ignored = _ignored_paths([f.relative_to(REPO_ROOT) for f in out])
    return [f for f in out if str(f.relative_to(REPO_ROOT)) not in ignored]


def check_code_pointers(docs: dict[str, Doc], findings: list[str]) -> int:
    checked = 0
    for f in code_files():
        try:
            text = f.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        rel = f.relative_to(REPO_ROOT).as_posix()
        for lineno, line in enumerate(text.split("\n"), 1):
            for m in CODE_POINTER.finditer(line):
                ref, anchor = m.group(1), m.group(2)
                target = (f.parent / ref) if ref.startswith("../") else (REPO_ROOT / ref)
                checked += 1
                try:
                    key = target.resolve().relative_to(REPO_ROOT).as_posix()
                except ValueError:
                    key = ""
                other = docs.get(key)
                if other is None:
                    findings.append(f"[pointer] {rel}:{lineno} -> {ref}  (no such page)")
                elif anchor and anchor not in other.anchors:
                    findings.append(f"[pointer] {rel}:{lineno} -> {ref}#{anchor}  (no such heading)")
    return checked


def header_pointers() -> dict[str, str]:
    """{"<file>\t<page>": "<file>:<line>"} for every bare pointer (no anchor, no section sign) in a .sh/.py header."""
    found: dict[str, str] = {}
    for f in code_files():
        if f.suffix not in HEADER_SUFFIXES:
            continue
        try:
            head = f.read_text(encoding="utf-8").split("\n")[:HEADER_LINES]
        except UnicodeDecodeError:
            continue
        rel = f.relative_to(REPO_ROOT).as_posix()
        for lineno, line in enumerate(head, 1):
            if SECTION_SIGN in line:
                continue
            for m in CODE_POINTER.finditer(line):
                if m.group(2):
                    continue
                found.setdefault(f"{rel}\t{m.group(1)}", f"{rel}:{lineno}")
    return found


def check_header_pointers(findings: list[str]) -> int:
    """Two-way freeze: an unfrozen bare header pointer is new, a frozen one that is gone is stale."""
    found = header_pointers()
    frozen = load_keys(str(HEADER_ALLOW))
    for key in sorted(found):
        rel, page = key.split("\t")
        if Path(page).name in UNFREEZABLE_PAGES:
            findings.append(
                f"[header]  {found[key]} -> {page}  (a file header must not point at an "
                f"OPEN backlog page -- the entry is archived when it closes; re-point at "
                f"the durable page that explains the behaviour)"
            )
        elif key not in frozen:
            findings.append(
                f"[header]  {found[key]} -> {page}  (bare pointer in a file header; "
                f"name the section it means, or freeze it in {HEADER_ALLOW.name})"
            )
    for key in sorted(frozen - set(found)):
        findings.append(
            f"[header]  {key.replace(chr(9), '  ')}  "
            f"(STALE {HEADER_ALLOW.name} row -- the bare pointer is gone, delete the line)"
        )
    return len(found)


# A bare same-page reference ("(§ 1a)"); a captured filename makes it cross-file, and (?![\w.(]) skips licence clauses and dates.
LOCAL_SECTION_REF = re.compile(
    r"(?P<file>[A-Za-z0-9._/-]+\.md`?\s*(?:\]\([^)]*\))?\s*)?"
    + SECTION_SIGN
    + r"\s*(?P<sec>\d+[a-z]?)(?![\w.(])"
)
# The headings such a reference can name: "### 1d. Which model writes code".
NUMBERED_HEADING = re.compile(r"^#{2,6}\s+(\d+[a-z]?)\.", re.MULTILINE)


def check_local_section_refs(docs: dict[str, Doc], findings: list[str]) -> int:
    """Validate bare same-page section references, only on pages that define numbered sections."""
    checked = 0
    for doc in docs.values():
        if doc.is_archive:
            continue
        have = set(NUMBERED_HEADING.findall(doc.body))
        if not have:
            continue
        for m in LOCAL_SECTION_REF.finditer(doc.body):
            if m.group("file"):
                continue  # cross-file: check_section_refs owns it
            checked += 1
            if m.group("sec") in have:
                continue
            findings.append(
                f"[section] {doc.rel} {SECTION_SIGN} {m.group('sec')}  "
                f"(no such section on this page)"
            )
    return checked


def check_index_coverage(docs: dict[str, Doc], findings: list[str]) -> int:
    index_rst = DOCS / "index.rst"
    index_md = DOCS / "INDEX.md"
    if not index_rst.is_file() or not index_md.is_file():
        # Only the hub must keep an index; a consumer need not run Sphinx at all.
        if _is_hub():
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
    ap.add_argument("--root", metavar="DIR",
                    help="grade this checkout instead of the gate's own repo")
    args = ap.parse_args()

    global REPO_ROOT, DOCS, HEADER_ALLOW
    try:
        REPO_ROOT = Path(gate_scope.resolve_root(args.root, str(HUB_ROOT)))
    except gate_scope.ScopeError as exc:
        return gate_scope.die(exc)
    DOCS = REPO_ROOT / "docs"
    if not _is_hub():
        # The freeze file follows the root like every ratchet; absent means nothing frozen.
        HEADER_ALLOW = REPO_ROOT / HEADER_ALLOW.name

    if _is_hub() and not DOCS.is_dir():
        print("ERROR: docs/ not found -- run from the repo (or fix REPO_ROOT)", file=sys.stderr)
        return 2

    try:
        docs = collect()
    except gate_scope.ScopeError as exc:
        return gate_scope.die(exc)
    if not docs:
        print("ERROR: no Markdown found to check", file=sys.stderr)
        return 2

    findings: list[str] = []
    n_links, n_anchors = check_links_and_anchors(docs, findings)
    n_sections = check_section_refs(docs, findings)
    n_sections += check_local_section_refs(docs, findings)
    n_pages = check_index_coverage(docs, findings)
    n_pointers = check_code_pointers(docs, findings)
    n_headers = check_header_pointers(findings)

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
            f"{n_pages} pages index-covered, {n_pointers} code pointers, "
            f"{n_headers} bare header pointers frozen."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
