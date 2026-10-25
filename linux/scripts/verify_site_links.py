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
from html.parser import HTMLParser
from urllib.parse import unquote, urljoin, urlsplit

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from quality_allow import check_keys, load_keys  # noqa: E402

SITE = "http://site.invalid/site/"
SKIP_SCHEMES = ("mailto:", "javascript:", "data:", "tel:", "about:")
REFRESH_URL = re.compile(r"url\s*=\s*['\"]?([^'\";]+)", re.IGNORECASE)
LINE_RANGE = re.compile(r"^(\d+)-(\d+)$")


class Page(HTMLParser):
    """The ids a page defines, its <base href>, and every link it carries."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.ids, self.links, self.base, self.is_document = set(), [], None, False

    def handle_decl(self, decl):
        self.is_document = self.is_document or decl.lower().startswith("doctype html")

    def handle_starttag(self, tag, attrs):
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


def parse(path):
    """One parse per file: a Page, or None when the file cannot be read as text."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return None
    page = Page()
    page.feed(text)
    return page


def site_target(base, link):
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


def target_file(site, rel):
    """The file a site path serves (a directory serves its index.html), or None."""
    if rel.startswith("../"):
        return None
    path = os.path.join(site, *[p for p in rel.split("/") if p])
    if os.path.isdir(path):
        path = os.path.join(path, "index.html")
    return path if os.path.isfile(path) else None


def anchor_ok(ids, fragment):
    """An id or name on the page (as written or decoded, as a browser tries), #top, or a rustdoc line range."""
    if not fragment or fragment == "top" or fragment in ids or unquote(fragment) in ids:
        return True
    m = LINE_RANGE.match(fragment)
    return bool(m) and m.group(1) in ids and m.group(2) in ids


class Site:
    """A built tree: its documents, parsed once each, and the findings over their links."""

    def __init__(self, root) -> None:
        self.root = os.path.abspath(root)
        self.pages, self.findings = {}, {}

    def page(self, path):
        if path not in self.pages:
            self.pages[path] = parse(path)
        return self.pages[path]

    def documents(self):
        for dirpath, dirnames, filenames in os.walk(self.root):
            dirnames.sort()
            for name in sorted(filenames):
                if name.endswith((".html", ".htm")):
                    yield os.path.join(dirpath, name)

    def note(self, key, source):
        self.findings.setdefault(key, set()).add(source)

    def check_link(self, rel_page, base, link):
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
                self.note("anchor\t%s#%s" % (rel_target, fragment), rel_page)

    def check(self):
        """Walk every document (a fragment dartdoc injects by script is not one) and check its links."""
        count = 0
        for path in self.documents():
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


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("site", help="the built HTML tree")
    ap.add_argument("--allow", default="", help="known exceptions, one tab-separated key per line")
    ap.add_argument("--print-keys", action="store_true", help="print every finding as an allow-file key and exit 0")
    args = ap.parse_args(argv)
    if not os.path.isdir(args.site):
        print("ERROR: %s is not a directory" % args.site, file=sys.stderr)
        return 2
    if args.allow and not os.path.isfile(args.allow):
        print("ERROR: allow file %s does not exist" % args.allow, file=sys.stderr)
        return 2
    site = Site(args.site)
    count = site.check()
    if args.print_keys:
        for key in sorted(site.findings):
            print(key)
        return 0
    frozen = load_keys(args.allow) if args.allow else set()
    print("=== built-site link gate ===")
    print("  site:  %s\n  allow: %s\n  pages: %d documents, %d finding(s), %d frozen"
          % (site.root, args.allow or "(none)", count, len(site.findings), len(frozen)))

    def describe(key) -> str:
        sources = sorted(site.findings.get(key, ()))
        return key.replace("\t", "  ") + ("   <- " + ", ".join(sources[:3]) if sources else "")

    rc = check_keys(site.findings, frozen, "FAIL: links that resolve to nothing on the built site:",
                    "FAIL: STALE allow entries, which resolve now -- delete them:", describe)
    if rc == 0:
        print("OK: every internal link and anchor resolves")
    return rc


if __name__ == "__main__":
    sys.exit(main())
