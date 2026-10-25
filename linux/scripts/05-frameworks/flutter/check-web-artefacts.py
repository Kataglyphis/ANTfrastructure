#!/usr/bin/env python3
"""A Flutter web app's committed artefacts against their pins: title and manifest name, sqlite3.wasm, 8-bit icons, icon paths.

docs/code-quality-tooling.md#the-flutter-web-artefacts-gate
"""
import argparse
import hashlib
import json
import pathlib
import re
import sys
import urllib.parse

VERSIONS_ENV = pathlib.Path(__file__).resolve().parents[2] / "01-core" / "versions.env"
# The generated icons: flutter_launcher_icons writes 16 bits per channel, a browser shows 8.
ICON_DIRS = ("web", "android/app/src/main/res")


def pins() -> dict[str, str]:
    """KEY=VALUE lines of the hub's versions.env."""
    found = {}
    for line in VERSIONS_ENV.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^([A-Z0-9_]+)=(\S*)", line)
        if m:
            found[m.group(1)] = m.group(2)
    return found


def check_title(root: pathlib.Path) -> list[str]:
    index, manifest = root / "web/index.html", root / "web/manifest.json"
    if not index.is_file() or not manifest.is_file():
        return []
    title = re.search(r"<title>([^<]*)</title>", index.read_text(encoding="utf-8"))
    name = json.loads(manifest.read_text(encoding="utf-8")).get("name")
    if not title:
        return ["web/index.html has no <title>"]
    if title.group(1).strip() != name:
        return [f"web/index.html's <title> is {title.group(1).strip()!r} but web/manifest.json's name is {name!r}: an installed app and its tab would disagree"]
    return []


def check_sqlite(root: pathlib.Path, pinned: dict[str, str]) -> list[str]:
    wasm = root / "web/sqlite3.wasm"
    if not wasm.is_file():
        return []
    problems = []
    digest = hashlib.sha256(wasm.read_bytes()).hexdigest()
    if digest != pinned.get("SQLITE3_WASM_SHA256"):
        problems.append(
            f"web/sqlite3.wasm is sha256 {digest}, not SQLITE3_WASM_SHA256 {pinned.get('SQLITE3_WASM_SHA256')}: "
            "refresh it with linux/scripts/05-frameworks/flutter/setup-sqlite3-wasm.sh, never by hand"
        )
    lock = root / "pubspec.lock"
    if lock.is_file():
        m = re.search(r'^  sqlite3:\r?\n(?:    .*\r?\n)*?    version: "([^"]+)"', lock.read_text(encoding="utf-8"), re.MULTILINE)
        if m and m.group(1) != pinned.get("SQLITE3_WASM_VERSION"):
            problems.append(
                f"pubspec.lock resolves sqlite3 {m.group(1)} but web/sqlite3.wasm is the {pinned.get('SQLITE3_WASM_VERSION')} build: "
                "move the hub pin, web/sqlite3.wasm and the lock together"
            )
    return problems


def check_icons(root: pathlib.Path) -> list[str]:
    deep = []
    for d in ICON_DIRS:
        for png in sorted((root / d).rglob("*.png")) if (root / d).is_dir() else []:
            header = png.read_bytes()[:25]
            if len(header) == 25 and header[24] != 8:
                deep.append(png.relative_to(root).as_posix())
    if not deep:
        return []
    return [
        "not 8 bits per channel: " + ", ".join(deep)
        + '. Re-encode them: python3 -c "import sys; from PIL import Image; '
        '[Image.open(p).save(p, optimize=True, compress_level=9) for p in sys.argv[1:]]" <files>'
    ]


def icon_refs(root: pathlib.Path) -> list[tuple[str, str, str]]:
    """The icons web/manifest.json and web/index.html name: (file, value, path on the site)."""
    refs = []
    manifest, index = root / "web/manifest.json", root / "web/index.html"
    if manifest.is_file():
        refs += [("web/manifest.json", icon.get("src", "")) for icon in json.loads(manifest.read_text(encoding="utf-8")).get("icons", [])]
    if index.is_file():
        html = index.read_text(encoding="utf-8")
        refs += [("web/index.html", m.group(1)) for m in re.finditer(r'<link\b[^>]*\brel="[^"]*icon[^"]*"[^>]*\bhref="([^"]*)"', html)]
        refs += [("web/index.html", m.group(1)) for m in re.finditer(r'<meta\b[^>]*\bproperty="og:image"[^>]*\bcontent="([^"]*)"', html)]
    return [(where, value, urllib.parse.urlsplit(value).path if "://" in value else "/" + value.removeprefix("./")) for where, value in refs]


def check_icon_paths(root: pathlib.Path, icons_dir: str) -> list[str]:
    """Each relative icon reference on disk, the manifest's under --icons-dir; on Apache, nothing under /icons/."""
    problems = []
    for where, value, site in icon_refs(root):
        if "://" not in value and not value.startswith("data:") and not (root / "web" / site.lstrip("/")).is_file():
            problems.append(f"{where} names {value}, which web/ does not hold")
        if where == "web/manifest.json" and not site.startswith(f"/{icons_dir}/"):
            problems.append(f"{where} names {value}, outside the icon directory web/{icons_dir}/")
    # A web/.htaccess means Apache serves the site, and its default Alias /icons/ answers that path from its own directory.
    if (root / "web/.htaccess").is_file():
        stray = sorted(p.relative_to(root).as_posix() for p in (root / "web/icons").rglob("*") if p.is_file()) if (root / "web/icons").is_dir() else []
        named = sorted({value for _where, value, site in icon_refs(root) if site.startswith("/icons/")})
        if stray or named:
            problems.append(
                "Apache serves /icons/ from its own directory, so these 404 on the site: "
                + ", ".join(stray + named)
                + ". Move them to another directory (e.g. web/app-icons/, --icons-dir app-icons); see docs/failure-modes.md"
            )
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo-root", default=".", help="the Flutter app's root (default: the current directory)")
    parser.add_argument("--icons-dir", default="icons", help="the directory under web/ that holds the manifest's icons (default: icons)")
    args = parser.parse_args()
    root = pathlib.Path(args.repo_root).resolve()
    if not (root / "pubspec.yaml").is_file():
        print(f"check-web-artefacts: {root} has no pubspec.yaml", file=sys.stderr)
        return 2
    problems = check_title(root) + check_sqlite(root, pins()) + check_icons(root) + check_icon_paths(root, args.icons_dir.strip("/"))
    for problem in problems:
        print(f"FAIL: {problem}")
    if not problems:
        print("Web artefacts match their pins.")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
