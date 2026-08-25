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


def _resolve_ref(src: dict, versions: dict[str, str]) -> str:
    if src.get("ref_var"):
        return versions.get(src["ref_var"], "—")
    return src.get("ref", "—")


def render_obligations_lines() -> list[str]:
    """What the licences present in this tree require of the distributor."""
    import license_obligations as lo

    metadata = load_deps_metadata()
    present: dict[str, list[str]] = {}
    for section in metadata["sections"]:
        for subsection in section["subsections"]:
            for entry in subsection["entries"]:
                for ob in lo.obligations_for(entry["spdx"]):
                    present.setdefault(ob, []).append(entry["name"])

    order = [o for o in lo.DESCRIPTIONS if o in present]
    lines = ["", "## What these licences require", "",
             "Every obligation below is triggered by at least one component actually shipped in "
             "an image on this page. This is a structured reading of the licence texts, not legal "
             "advice.", ""]
    for ob in order:
        lines.append(f"- **{ob}** — {lo.DESCRIPTIONS[ob]}")
    lines.append("")
    return lines


def render_source_offer_lines(versions: dict[str, str]) -> list[str]:
    """The corresponding-source pointers for every copyleft component.

    GPL/LGPL/MPL require the complete corresponding source, or a written offer,
    to accompany the binary. Publishing the image without either is the single
    obligation most often missed, so the pointers are generated from the same
    pins the build uses and cannot drift from them.
    """
    import license_obligations as lo

    metadata = load_deps_metadata()
    rows: list[tuple[str, str, dict]] = []
    for section in metadata["sections"]:
        for subsection in section["subsections"]:
            for entry in subsection["entries"]:
                if lo.requires_source(entry["spdx"]) and entry.get("source"):
                    # Qualified by image: FFmpeg and GStreamer appear in both the
                    # Linux and Windows sections with DIFFERENT patch sets, so an
                    # unqualified heading would collide and hide one of them.
                    label = f"{entry['name']} — {section['title']}"
                    rows.append((label, entry["spdx"], entry["source"]))

    lines = ["", "## Corresponding source", "",
             "The components below are copyleft-licensed, so their source must accompany the "
             "binaries. Each entry names the exact upstream and the revision this project builds, "
             "any patches applied on top, and — where the build configuration is what determines "
             "the licence — the flags used.", "",
             "If a link ever fails to resolve, the obligation stands: request the corresponding "
             "source and it will be provided.", ""]
    for name, spdx, src in rows:
        ref = _resolve_ref(src, versions)
        url = src.get("url", "")
        lines.append(f"### {name}")
        lines.append("")
        lines.append(f"- **Licence:** {spdx}")
        if url:
            lines.append(f"- **Source:** <{url}>")
        lines.append(f"- **Revision:** {ref}")
        if src.get("build_flags"):
            lines.append(f"- **Build configuration:** `{src['build_flags']}`")
        if src.get("patches"):
            lines.append(f"- **Patches applied:** {', '.join(f'`{p}`' for p in src['patches'])}")
        if src.get("note"):
            lines.append(f"- {src['note']}")
        lines.append("")
    return lines


def render_modified_lines() -> list[str]:
    """Components this project patches before redistributing.

    Apache-2.0 section 4(b) and the GPL family both require saying so.
    """
    metadata = load_deps_metadata()
    rows = [
        (f"{e['name']} — {s['title']}", e["modified"])
        for s in metadata["sections"] for sub in s["subsections"] for e in sub["entries"]
        if e.get("modified")
    ]
    if not rows:
        return []
    lines = ["", "## Modified components", "",
             "This project patches the following upstreams before redistributing them. Both the "
             "Apache-2.0 and the GPL families require that modification be stated.", ""]
    for name, mod in rows:
        patches = ", ".join(f"`{p}`" for p in mod.get("patches", []))
        lines.append(f"- **{name}** — {mod.get('note', '')}"
                     + (f" Patches: {patches}." if patches else ""))
    lines.append("")
    lines.append("Each patch is in this repository at the path shown, and travels with the "
                 "corresponding source above.")
    lines.append("")
    return lines


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
