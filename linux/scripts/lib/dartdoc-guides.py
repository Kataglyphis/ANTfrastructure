#!/usr/bin/env python3
"""Render staged Markdown guides into a `dart doc` or rustdoc site. See docs/shared-script-libraries.md#dartdoc-buildsh--theme-and-enrich-a-dart-doc-site"""

from __future__ import annotations

import html
import os
import pathlib
import posixpath
import re
import subprocess
import sys
from urllib.parse import quote, unquote

from markdown_it import MarkdownIt

RENDERER = MarkdownIt(
    "commonmark", {"html": False, "linkify": True, "typographer": True}
).enable("table")

MAIN_START = '<div id="dartdoc-main-content" class="main-content">'
MAIN_END = "  </div> <!-- /.main-content -->"
RIGHT_START = '<div id="dartdoc-sidebar-right" class="sidebar sidebar-offcanvas-right">'
RIGHT_END = "  </div>\n</main>"
LEFT_START = '<div id="dartdoc-sidebar-left"'
# rustdoc's shell is a crate's index.html: a guide written beside it keeps its relative paths.
RUST_MAIN_START = '<section id="main-content" class="content"'
RUST_MAIN_END = "</section></div></main>"
RUST_TOC_START = '<section id="rustdoc-toc">'
RUST_TOC_END = "</section>"
RUST_SIDEBAR = '<div class="sidebar-elems">'
RUST_TOPBAR = re.compile(r'(<rustdoc-topbar><h2><a href="#">).*?(</a>)', re.S)
FLAVORS = ("dartdoc", "rustdoc")
NAV_MARKER = "kg-md-nav-section"
FOOTER_MARKER = "kg-doc-footer-links"
# The family links every repository on develop: docs/repository-family.md#the-readme-rule
BRANCH = "develop"
# A scheme, a protocol-relative or site-absolute path, or a same-page anchor: not a path into the repository.
NOT_A_REPO_PATH = re.compile(r"^(?:[A-Za-z][A-Za-z0-9+.-]*:|/|#)")
GITHUB_REMOTE = re.compile(
    r"^(?:https://(?:[^@/]+@)?github\.com/|git@github\.com:|ssh://git@github\.com/)"
    r"([\w.-]+/[\w.-]+?)(?:\.git)?/?$"
)


def load_config(path):
    """Parse the tab-separated config: title_suffix, footer_title, project_root, repo_url, flavor, shell, guide, footer."""
    config = {"title_suffix": "", "footer_title": "", "project_root": "", "repo_url": "",
              "flavor": "dartdoc", "shell": "index.html", "guides": [], "sources": {}, "footer": []}
    text = pathlib.Path(path).read_text(encoding="utf-8")
    for lineno, raw in enumerate(text.splitlines(), 1):
        if not raw.strip():
            continue
        fields = raw.split("\t")
        key = fields[0]
        if key == "flavor" and len(fields) == 2 and fields[1] not in FLAVORS:
            raise SystemExit(f"{path}:{lineno}: flavor must be one of {', '.join(FLAVORS)}, got {fields[1]!r}")
        if key in ("title_suffix", "footer_title", "project_root", "repo_url", "flavor", "shell") and len(fields) == 2:
            config[key] = fields[1]
        elif key == "guide" and len(fields) == 4:
            config["guides"].append((fields[1], fields[2]))
            config["sources"][fields[1]] = fields[3]
        elif key == "footer" and len(fields) == 3:
            config["footer"].append((fields[1], fields[2]))
        else:
            raise SystemExit(f"{path}:{lineno}: unrecognised config row: {raw!r}")
    return config


def github_url(remote: str) -> str:
    """https://github.com/<owner>/<repo> for a GitHub remote in any of git's spellings, else ''."""
    match = GITHUB_REMOTE.match(remote.strip())
    return f"https://github.com/{match.group(1)}" if match else ""


def origin_url(root: str) -> str:
    """The checkout's origin as a GitHub URL; '' without git, a remote or a GitHub one."""
    try:
        out = subprocess.run(["git", "-c", "safe.directory=*", "-C", root, "remote", "get-url", "origin"],
                             capture_output=True, text=True, check=False)
    except OSError:
        return ""
    return github_url(out.stdout) if out.returncode == 0 else ""


def submodule_urls(root: str):
    """[(path, GitHub URL)] from <root>/.gitmodules, longest path first; a non-GitHub one is left out."""
    gitmodules = pathlib.Path(root) / ".gitmodules"
    if not root or not gitmodules.is_file():
        return []
    found, path = [], None
    for line in gitmodules.read_text(encoding="utf-8", errors="ignore").splitlines():
        key, _, value = (part.strip() for part in line.partition("="))
        if line.lstrip().startswith("["):
            path = None
        elif key == "path":
            path = value.strip("/")
        elif key == "url" and path and github_url(value):
            found.append((path, github_url(value)))
    return sorted(found, key=lambda item: -len(item[0]))


def repo_path(root: str, source: str) -> str:
    """A guide source's path relative to the project root, in the slashes a link uses."""
    return os.path.relpath(os.path.abspath(source), os.path.abspath(root)).replace(os.sep, "/")


class LinkTargets:
    """Where a relative link in a guide goes: the guide rendered from it, or the file or folder on GitHub."""

    def __init__(self, guide_pages: dict, repo_url: str = "", submodules=(), project_root: str = "",
                 site_root: str = ""):
        self.guide_pages = guide_pages
        self.repo_url = repo_url.rstrip("/")
        self.submodules = list(submodules)
        self.project_root = project_root
        self.site_root = site_root

    def kind(self, resolved: str) -> str:
        """blob for a file, tree for a folder, '' for nothing; blob unchecked without a project root."""
        if not self.project_root:
            return "blob"
        found = pathlib.Path(self.project_root, resolved)
        if found.is_dir():
            return "tree"
        if found.is_file():
            return "blob"
        for sub, _ in self.submodules:
            checkout = pathlib.Path(self.project_root, sub)
            # A submodule the build did not check out cannot be looked into.
            if (resolved + "/").startswith(sub + "/") and checkout.is_dir() and not any(checkout.iterdir()):
                return "blob"
        return ""

    def target(self, source_rel: str, path: str) -> str:
        resolved = posixpath.normpath(posixpath.join(posixpath.dirname(source_rel), unquote(path)))
        if resolved in self.guide_pages:
            return self.guide_pages[resolved]
        if resolved == ".." or resolved.startswith("../"):
            raise SystemExit(f"{source_rel}: the link {path!r} leaves the repository; "
                             "link another repository by its absolute URL.")
        kind = self.kind(resolved)
        if not kind:
            if self.site_root and pathlib.Path(self.site_root, unquote(path)).exists():
                return path
            raise SystemExit(f"{source_rel}: the link {path!r} names nothing in the repository "
                             f"({resolved}) and no page of the site.")
        for sub, url in self.submodules:
            if resolved == sub:
                return f"{url}/tree/{BRANCH}"
            if resolved.startswith(sub + "/"):
                return f"{url}/{kind}/{BRANCH}/{quote(resolved[len(sub) + 1:])}"
        if not self.repo_url:
            raise SystemExit(f"{source_rel}: the link {path!r} names no guide, and the repository's "
                             "GitHub URL is unknown (no GitHub origin); set DARTDOC_BUILD_REPO_URL.")
        return f"{self.repo_url}/{kind}/{BRANCH}/{quote(resolved)}"


def slugify(value: str) -> str:
    """GitHub's heading anchor, so a `page.md#anchor` written for GitHub lands on the guide page too."""
    return re.sub(r"[^\w\- ]", "", value.strip().lower()).replace(" ", "-") or "section"


def rewrite_md_links(rendered_html: str, links: LinkTargets, source_rel: str) -> str:
    """Point every relative link, anchor kept, at its guide page or, failing that, at GitHub."""

    def repl(match):
        prefix, href, suffix = match.group(1), match.group(2), match.group(3)
        if NOT_A_REPO_PATH.match(href):
            return match.group(0)
        path, sep, fragment = href.partition("#")
        return f"{prefix}{links.target(source_rel, path)}{sep}{fragment}{suffix}"

    return re.sub(r'(href\s*=\s*["\'])([^"\']+)(["\'])', repl, rendered_html)


def extract_headings(markdown_text: str):
    headings = []
    tokens = RENDERER.parse(markdown_text)
    for i, token in enumerate(tokens):
        if token.type != "heading_open":
            continue
        inline = tokens[i + 1] if i + 1 < len(tokens) else None
        title = (inline.content if inline and inline.type == "inline" else "").strip()
        if title:
            headings.append((int(token.tag[1]), title, slugify(title)))
    return headings


def add_heading_ids(rendered_html: str, headings) -> str:
    """Give each heading the anchor the table of contents links to."""
    cursor = 0
    for level, _title, anchor in headings:
        tag = f"<h{level}>"
        idx = rendered_html.find(tag, cursor)
        if idx == -1:
            continue
        replacement = f'<h{level} id="{anchor}">'
        rendered_html = rendered_html[:idx] + replacement + rendered_html[idx + len(tag) :]
        cursor = idx + len(replacement)
    return rendered_html


def build_toc(headings) -> str:
    if not headings:
        return ""
    items = [
        f'<li class="{"section-subitem" if level > 2 else "section-title"}">'
        f'<a href="#{anchor}">{html.escape(title)}</a></li>'
        for level, title, anchor in headings
    ]
    return "\n".join(
        ['<h5 class="hidden-xs">Guide Contents</h5>', '<ol class="kg-guide-toc">', *items, "</ol>"]
    )


def build_rustdoc_toc(nav_title: str, headings) -> str:
    """rustdoc's sidebar contents: the guide's title, then each ## heading with its ### headings."""
    sections = []
    for level, title, anchor in headings:
        link = f'<a href="#{anchor}" title="{html.escape(title)}">{html.escape(title)}</a>'
        if level == 2:
            sections.append((link, []))
        elif level == 3 and sections:
            sections[-1][1].append(f"<li>{link}</li>")
    items = "".join(f"<li>{link}{'<ul>' + ''.join(subs) + '</ul>' if subs else ''}</li>" for link, subs in sections)
    toc = f'<h2 class="location"><a href="#">{html.escape(nav_title)}</a></h2>'
    return toc + (f'<h3><a href="#">Sections</a></h3><ul class="block top-toc">{items}</ul>' if items else "")


def _splice(page: str, start: str, end: str, replacement: str, where: str) -> str:
    """Replace the region between two landmarks; a missing one is fatal, as the generators' HTML is unstable."""
    start_idx = page.find(start)
    end_idx = page.find(end, start_idx) if start_idx != -1 else -1
    if start_idx == -1 or end_idx <= start_idx:
        missing = start if start_idx == -1 else end
        raise SystemExit(
            f"{where}: the generator's page shell no longer contains {missing!r}. "
            "The renderer's landmarks must be updated to match the generator; "
            "it will not report a rendered page it did not render."
        )
    return page[:start_idx] + replacement + page[end_idx:]


def render_guide_page(shell, nav_title: str, suffix: str, md_text: str, links, slug, source_rel,
                      flavor: str = "dartdoc") -> str:
    headings = extract_headings(md_text)
    body = add_heading_ids(rewrite_md_links(RENDERER.render(md_text), links, source_rel), headings)
    title = f"{nav_title} - {suffix}" if suffix else nav_title
    page, n = re.subn(
        r"<title>.*?</title>", f"<title>{html.escape(title)}</title>", shell, count=1, flags=re.S
    )
    if n != 1:
        raise SystemExit(f"guide-{slug}.html: no <title> in the page shell.")
    if flavor == "rustdoc":
        main = f'{RUST_MAIN_START} tabindex="-1">\n<div class="docblock kg-guide-content">\n{body}\n</div>\n'
        page = _splice(page, RUST_MAIN_START, RUST_MAIN_END, main, f"guide-{slug}.html (main content)")
        page = _splice(page, RUST_TOC_START, RUST_TOC_END, RUST_TOC_START + build_rustdoc_toc(nav_title, headings),
                       f"guide-{slug}.html (sidebar contents)")
        # The mobile top bar names the page; an older rustdoc has none, so it is optional.
        return RUST_TOPBAR.sub(lambda m: m.group(1) + html.escape(nav_title) + m.group(2), page, count=1)
    main = f'{MAIN_START}\n<section class="desc markdown kg-guide-content">\n{body}\n</section>\n'
    page = _splice(page, MAIN_START, MAIN_END, main, f"guide-{slug}.html (main content)")
    return _splice(page, RIGHT_START, RIGHT_END, f"{RIGHT_START}\n{build_toc(headings)}\n",
                   f"guide-{slug}.html (right sidebar)")


def sidebar_nav(guide_dir: pathlib.Path, page_path: pathlib.Path, guides, flavor: str = "dartdoc") -> str:
    """The guides block, 'Markdown Guides' or rustdoc's 'Guides', with every href relative to the page holding it."""
    links = []
    for slug, label in guides:
        target = guide_dir / f"guide-{slug}.html"
        if target.exists():
            links.append((os.path.relpath(target, page_path.parent).replace(os.sep, "/"), label))
    if not links:
        return ""
    if flavor == "rustdoc":
        items = "".join(f'<li><a href="{href}">{html.escape(label)}</a></li>' for href, label in links)
        return f'<section class="{NAV_MARKER}"><h3>Guides</h3><ul class="block">{items}</ul></section>'
    items = [f'      <li class="section-subitem kg-md-nav-item"><a href="{href}">{label}</a></li>'
             for href, label in links]
    return "\n".join([f'      <li class="section-title {NAV_MARKER}">Markdown Guides</li>', *items])


def inject_sidebar_nav(text: str, nav_html: str, where, flavor: str = "dartdoc") -> str:
    """Hang the guide nav off dartdoc's left sidebar's first `<ol>` or atop rustdoc's sidebar; else skip the page."""
    if NAV_MARKER in text or not nav_html:
        return text
    if flavor == "rustdoc":
        at = text.find(RUST_SIDEBAR)
        return text if at == -1 else text[: at + len(RUST_SIDEBAR)] + nav_html + text[at + len(RUST_SIDEBAR) :]
    sidebar = text.find(LEFT_START)
    ol_start = text.find("<ol>", sidebar) if sidebar != -1 else -1
    if ol_start == -1:
        return text
    at = text.find("\n", ol_start)
    at = ol_start + len("<ol>") if at == -1 else at
    return text[: at + 1] + nav_html + "\n" + text[at + 1 :]


def inject_footer(text: str, footer_html: str, where) -> str:
    if FOOTER_MARKER in text or not footer_html:
        return text
    if "</footer>" in text:
        return text.replace("</footer>", f"{footer_html}\n</footer>")
    if "</body>" in text:
        return text.replace("</body>", f"<footer>\n{footer_html}\n</footer>\n</body>")
    # A *-sidebar.html fragment has no <html, and a footer there would land mid-sidebar.
    if "<html" not in text:
        return text
    raise SystemExit(f"{where}: neither '</footer>' nor '</body>' to attach the footer to.")


def build_footer(title: str, links) -> str:
    if not title and not links:
        return ""
    anchors = [f'    <a href="{html.escape(url)}">{html.escape(label)}</a>' for label, url in links]
    return "\n".join(
        [
            f'  <div class="{FOOTER_MARKER}">',
            f"    <strong>{html.escape(title)}</strong>",
            *anchors,
            "  </div>",
        ]
    )


def main(argv) -> int:
    if len(argv) != 3:
        raise SystemExit(f"usage: {argv[0]} <site dir> <config file>")
    root = pathlib.Path(argv[1])
    config = load_config(argv[2])
    guides = config["guides"]
    flavor = config["flavor"]
    # Each guide page is written beside its shell, so the shell's relative links hold on it.
    shell_path = root / config["shell"]
    guide_dir = shell_path.parent
    project = config["project_root"] or os.getcwd()
    sources = {slug: repo_path(project, src) for slug, src in config["sources"].items()}
    links = LinkTargets({rel: f"guide-{slug}.html" for slug, rel in sources.items()},
                        config["repo_url"] or origin_url(project), submodule_urls(project), project, str(guide_dir))
    if guides and not shell_path.is_file():
        raise SystemExit(f"No page shell at {shell_path}: the site was not built, or names its pages otherwise.")
    shell = shell_path.read_text(encoding="utf-8", errors="ignore") if guides else ""

    for slug, label in guides:
        source = root / "md" / f"{slug}.md"
        if not source.exists():
            raise SystemExit(f"Staged guide is missing: {source}")
        md_text = source.read_text(encoding="utf-8", errors="ignore")
        page = render_guide_page(shell, label, config["title_suffix"], md_text, links, slug, sources[slug], flavor)
        (guide_dir / f"guide-{slug}.html").write_text(page, encoding="utf-8")

    footer_html = build_footer(config["footer_title"], config["footer"])
    navigated = 0
    footered = 0
    pages = 0
    for page_path in sorted(root.rglob("*.html")):
        pages += 1
        rel = page_path.relative_to(root)
        text = page_path.read_text(encoding="utf-8", errors="ignore")
        nav_html = sidebar_nav(guide_dir, page_path, guides, flavor)
        after = inject_sidebar_nav(text, nav_html, rel, flavor)
        # Count the marker, not this run's edits, so a second pass is a no-op.
        navigated += NAV_MARKER in after
        final = inject_footer(after, footer_html, rel)
        footered += FOOTER_MARKER in final
        page_path.write_text(final, encoding="utf-8")
    # Counted, not assumed: "Rendered N" over an untouched tree must fail.
    if guides and not navigated:
        raise SystemExit(
            f"{len(guides)} guide page(s) rendered but not one of the {pages} page(s) "
            f"under {root} carries the guide navigation; the site would not link them."
        )
    # Fragments are skipped, so a footer attached to nothing would otherwise pass.
    if footer_html and not footered:
        raise SystemExit(
            f"a footer is configured but not one of the {pages} page(s) under {root} "
            "received it; every page was skipped as a fragment, which cannot be right."
        )
    print(
        f"Rendered {len(guides)} guide page(s), navigated {navigated}/{pages} "
        f"and footered {footered}/{pages} under {root}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
