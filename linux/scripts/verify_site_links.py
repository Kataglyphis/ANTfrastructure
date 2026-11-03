#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Built-site link gate: every internal link and anchor of a built HTML tree resolves, offline.

usage: verify_site_links.py <site dir> [--allow FILE] [--print-keys]
docs/docs-sites.md#the-built-site-link-gate
"""

import argparse
import os
import posixpath
import re
import sys
from collections.abc import Iterator, Sequence
from concurrent.futures import ProcessPoolExecutor
from dataclasses import dataclass
from html.parser import HTMLParser
from urllib.parse import unquote, urljoin, urlsplit

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from quality_allow import check_keys, load_keys

SITE = "http://site.invalid/site/"
SKIP_SCHEMES = ("mailto:", "javascript:", "data:", "tel:", "about:")
REFRESH_URL = re.compile(r"url\s*=\s*['\"]?([^'\";]+)", re.IGNORECASE)
LINE_RANGE = re.compile(r"^(\d+)-(\d+)$")


@dataclass(frozen=True)
class PageFacts:
    """What the link check reads from a parsed page, plain enough to cross a process boundary."""
    ids: set[str]
    links: list[str]
    base: str | None
    is_document: bool


class Page(HTMLParser):
    """The ids a page defines, its <base href>, and every link it carries."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.ids: set[str] = set()
        self.links: list[str] = []
        self.base: str | None = None
        self.is_document = False

    def handle_decl(self, decl: str) -> None:
        self.is_document = self.is_document or decl.lower().startswith("doctype html")

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        a = {k: (v or "").strip() for k, v in attrs}
        self.is_document = self.is_document or tag == "html"
        if a.get("id"):
            self.ids.add(a["id"])
        if tag == "a" and a.get("name"):
            self.ids.add(a["name"])
        if tag == "base":
            self.base = self.base or a.get("href") or None
            return
        if tag == "meta" and a.get("http-equiv", "").lower() == "refresh":
            m = REFRESH_URL.search(a.get("content", ""))
            if m:
                self.links.append(m.group(1).strip())
        for attr in ("href", "src"):
            if a.get(attr):
                self.links.append(a[attr])

    handle_startendtag = handle_starttag


def parse(path: str) -> PageFacts | None:
    """One parse per file: its facts, or None when the file cannot be read as text."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return None
    page = Page()
    page.feed(text)
    return PageFacts(page.ids, page.links, page.base, page.is_document)


def site_link_jobs() -> int:
    """SITE_LINK_JOBS, default one per CPU; 1 parses in this process."""
    value = os.environ.get("SITE_LINK_JOBS", "") or str(os.cpu_count() or 1)
    if not value.isascii() or not value.isdigit() or int(value) < 1:
        raise ValueError(f"SITE_LINK_JOBS={value} is not a positive integer")
    return int(value)


def site_target(base: str, link: str) -> tuple[str, str] | None:
    """(site-relative path, fragment) a link points at, or None when it leaves the site or names nothing."""
    if link.startswith(SKIP_SCHEMES) or link in ("", "#"):
        return None
    if link.startswith("/") and not link.startswith("//"):
        link = SITE + link[1:]
    parts = urlsplit(urljoin(base, link))
    if parts.scheme not in ("http", "https") or parts.netloc != urlsplit(SITE).netloc:
        return None
    path = posixpath.normpath(unquote(parts.path)) + ("/" if parts.path.endswith("/") else "")
    root = urlsplit(SITE).path
    rel = path[len(root):] if path.startswith(root) else "../" + path.lstrip("/")
    return rel, parts.fragment


def target_file(site: str, rel: str) -> str | None:
    """The file a site path serves (a directory serves its index.html), or None."""
    if rel.startswith("../"):
        return None
    path = os.path.join(site, *[p for p in rel.split("/") if p])
    if os.path.isdir(path):
        path = os.path.join(path, "index.html")
    return path if os.path.isfile(path) else None


def anchor_ok(ids: set[str], fragment: str) -> bool:
    """An id or name on the page (as written or decoded, as a browser tries), #top, or a rustdoc line range."""
    if not fragment or fragment == "top" or fragment in ids or unquote(fragment) in ids:
        return True
    m = LINE_RANGE.match(fragment)
    return bool(m) and m.group(1) in ids and m.group(2) in ids


class Site:
    """A built tree: its documents, parsed once each, and the findings over their links."""

    def __init__(self, root: str) -> None:
        self.root = os.path.abspath(root)
        self.pages: dict[str, PageFacts | None] = {}
        self.findings: dict[str, set[str]] = {}

    def page(self, path: str) -> PageFacts | None:
        if path not in self.pages:
            self.pages[path] = parse(path)
        return self.pages[path]

    def parse_all(self, paths: list[str], jobs: int) -> None:
        """Parse every document up front: the check itself reads them in one fixed order, so findings do not change."""
        if jobs > 1 and len(paths) > 1:
            with ProcessPoolExecutor(jobs) as pool:
                self.pages.update(zip(paths, pool.map(parse, paths, chunksize=16)))

    def documents(self) -> Iterator[str]:
        for dirpath, dirnames, filenames in os.walk(self.root):
            dirnames.sort()
            for name in sorted(filenames):
                if name.endswith((".html", ".htm")):
                    yield os.path.join(dirpath, name)

    def note(self, key: str, source: str) -> None:
        self.findings.setdefault(key, set()).add(source)

    def check_link(self, rel_page: str, base: str, link: str) -> None:
        hit = site_target(base, link)
        if hit is None:
            return
        rel, fragment = hit
        path = target_file(self.root, rel)
        if path is None:
            self.note("missing\t" + rel, rel_page)
        elif fragment and path.endswith((".html", ".htm")):
            target = self.page(path)
            if target is not None and not anchor_ok(target.ids, fragment):
                rel_target = os.path.relpath(path, self.root).replace(os.sep, "/")
                self.note(f"anchor\t{rel_target}#{fragment}", rel_page)

    def check(self) -> int:
        """Walk every document (a fragment dartdoc injects by script is not one) and check its links."""
        count = 0
        paths = list(self.documents())
        self.parse_all(paths, site_link_jobs())
        for path in paths:
            page = self.page(path)
            if page is None or not page.is_document:
                continue
            count += 1
            rel_page = os.path.relpath(path, self.root).replace(os.sep, "/")
            url = SITE + rel_page
            base = urljoin(url, page.base) if page.base else url
            for link in page.links:
                self.check_link(rel_page, base, link)
        if not os.path.isfile(os.path.join(self.root, "index.html")):
            self.note("missing\tindex.html", "(the site root)")
        return count


def main(argv: Sequence[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("site", help="the built HTML tree")
    ap.add_argument("--allow", default="", help="known exceptions, one tab-separated key per line")
    ap.add_argument("--print-keys", action="store_true", help="print every finding as an allow-file key and exit 0")
    args = ap.parse_args(argv)
    if not os.path.isdir(args.site):
        print(f"ERROR: {args.site} is not a directory", file=sys.stderr)
        return 2
    if args.allow and not os.path.isfile(args.allow):
        print(f"ERROR: allow file {args.allow} does not exist", file=sys.stderr)
        return 2
    site = Site(args.site)
    try:
        count = site.check()
    except ValueError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    if args.print_keys:
        for key in sorted(site.findings):
            print(key)
        return 0
    frozen = load_keys(args.allow) if args.allow else set()
    print("=== built-site link gate ===")
    print(
        f"  site:  {site.root}\n  allow: {args.allow or '(none)'}\n"
        f"  pages: {count} documents, {len(site.findings)} finding(s), {len(frozen)} frozen"
    )

    def describe(key: str) -> str:
        sources = sorted(site.findings.get(key, ()))
        return key.replace("\t", "  ") + ("   <- " + ", ".join(sources[:3]) if sources else "")

    rc = check_keys(site.findings, frozen, "FAIL: links that resolve to nothing on the built site:",
                    "FAIL: STALE allow entries, which resolve now -- delete them:", describe)
    if rc == 0:
        print("OK: every internal link and anchor resolves")
    return rc


if __name__ == "__main__":
    sys.exit(main())
