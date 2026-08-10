"""Shared deps-table renderer for sync_versions.py and generate-website-licenses.py.

Single source of truth for rendering docs/deps/deps.json into the markdown
dependency table (third-party-licenses.md block + website license pages).
Extracted 2026-08-10 (backlog F2): the two scripts carried duplicated
renderers with DIVERGENT missing-var behavior — generate-website-licenses.py
got the 2026-08-08 loud-KeyError fix while sync_versions.py still silently
em-dashed a renamed/removed versions.env key (and in --write mode had already
written the degraded table before exiting nonzero).

Behavior contract (the generate-website-licenses semantics):
  * an entry whose "var" is missing from the provided versions dict raises
    KeyError — loud, and BEFORE anything is written by either caller;
  * entries without "var" fall back to "version_fixed", else an em-dash.

Callers pass their own parsed versions dict (the two scripts' parsers
deliberately differ: sync_versions skips empty-valued keys) and wrap the
returned body lines however they need (marker comments, page templates).
"""

from __future__ import annotations

import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEPS_JSON_PATH = REPO_ROOT / "docs/deps/deps.json"


def load_deps_metadata() -> dict:
    return json.loads(DEPS_JSON_PATH.read_text(encoding="utf-8"))


def resolve_dep_version(entry: dict, versions: dict[str, str]) -> str:
    var = entry.get("var")
    if var:
        if var not in versions:
            # Loud failure: a renamed/removed versions.env key used to degrade
            # silently to version_fixed or an em-dash on the PUBLISHED pages.
            raise KeyError(
                f"deps.json entry {entry.get('name')!r}: var {var!r} "
                f"not found in versions.env"
            )
        return versions[var]
    fixed = entry.get("version_fixed")
    if fixed:
        return fixed
    return "—"


def render_deps_table_lines(versions: dict[str, str]) -> list[str]:
    """Render the table body as a list of lines (no surrounding markers).

    The body starts with an empty line (before the first section heading) and
    ends with an empty line (after the last table row) — both callers rely on
    that shape, so "\n".join(...) reproduces their historical output exactly.
    """
    metadata = load_deps_metadata()
    lines: list[str] = []

    for section in metadata["sections"]:
        title = section["title"]
        tag = section.get("tag", "")
        heading = f"## {title}"
        if tag:
            heading += f" (`{tag}`)"
        lines.append("")
        lines.append(heading)
        lines.append("")

        for subsection in section["subsections"]:
            subtitle = subsection["title"]
            df = subsection.get("dockerfile", "")
            sub_heading = f"### {subtitle}"
            if df:
                sub_heading += f" (`{df}`)"
            lines.append(sub_heading)
            lines.append("")
            lines.append("| Software | Version | Repository | License |")
            lines.append("| --- | --- | --- | --- |")

            for entry in subsection["entries"]:
                name = entry["name"]
                ver = resolve_dep_version(entry, versions)
                url = entry.get("url", "")
                lic = entry.get("license", "")
                if url:
                    display = url.replace("https://", "").replace("http://", "").rstrip("/")
                    repo = f"[{display}]({url})"
                else:
                    repo = "—"
                lines.append(f"| {name} | {ver} | {repo} | {lic} |")

            lines.append("")

    return lines
