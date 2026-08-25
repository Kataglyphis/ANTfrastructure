#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""Compare a scanner SBOM against the curated one, and show what each half sees.

The claim behind keeping two SBOMs is testable: an image scanner cannot
catalogue components built from source into `/opt`, because they leave no
package metadata behind, and those are precisely the copyleft ones. This prints
the evidence against a real scan instead of asserting it.

Two things this is careful about, because getting either wrong overstates the
blind spot:

  * **Distinct names vs package count.** A scan of 4,112 packages is not 4,112
    distinct components -- the same library appears per-architecture and
    per-path. Both numbers are reported.
  * **Which image the curated entry belongs to.** The curated document covers
    the Linux images, the Windows image, the webserver AND the documentation
    image. Comparing a Linux scan against the Windows rows would report
    Ghostscript and TeX Live as "invisible to the scanner", which is nonsense:
    they are not in that image at all. Curated entries are therefore filtered to
    the section matching the scanned platform.

Usage:
    python docs/scripts/compare_sbom.py out/sbom/scanned-linux-amd64.spdx.json
    python docs/scripts/compare_sbom.py out/sbom/scanned-windows-amd64.spdx.json --section Windows
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CURATED = REPO_ROOT / "docs/deps/sbom-curated.spdx.json"

SECTION_RE = re.compile(r"Image section:\s*([^/]+?)\s*/")


def normalise(name: str) -> str:
    """Strip everything but letters, and trailing version digits with them.

    Token EQUALITY is not enough here and produced false "invisible" verdicts:
    syft catalogues `gstreamer1.0` and `torch`, which never equal the curated
    `GStreamer` and `PyTorch`. Comparing letters-only, with containment in
    either direction, matches those correctly while still refusing to match
    OpenCV against anything (the scan genuinely has no OpenCV entry).
    """
    return re.sub(r"[^a-z]", "", name.lower())


def matches(curated_name: str, scanned: set[str]) -> bool:
    c = normalise(curated_name)
    if len(c) < 4:
        return curated_name.lower() in scanned
    for s in scanned:
        n = normalise(s)
        if len(n) < 4:
            continue
        if c in n or n in c:
            return True
    return False


def tokens(name: str) -> set[str]:
    """Kept for callers that want the loose token view."""
    return {t for t in re.split(r"[^a-z0-9]+", name.lower()) if len(t) > 2}


def infer_section(path: Path, explicit: str | None) -> str:
    if explicit:
        return explicit
    n = path.name.lower()
    if "windows" in n:
        return "Windows"
    if "linux" in n:
        return "Linux"
    return ""


def main() -> int:
    ap = argparse.ArgumentParser(description="Compare a scanner SBOM with the curated one.")
    ap.add_argument("scanned", type=Path, help="SPDX JSON produced by syft")
    ap.add_argument("--section", default=None,
                    help="curated section prefix to compare against (default: inferred "
                         "from the filename)")
    args = ap.parse_args()

    if not args.scanned.is_file():
        print(f"ERROR: {args.scanned} not found", file=sys.stderr)
        return 2
    scanned = json.loads(args.scanned.read_text(encoding="utf-8"))
    curated = json.loads(CURATED.read_text(encoding="utf-8"))

    section = infer_section(args.scanned, args.section)
    s_pkgs = scanned.get("packages", [])
    s_names = {p["name"].lower() for p in s_pkgs}

    ecos: Counter = Counter()
    for p in s_pkgs:
        purls = [r for r in p.get("externalRefs", []) if r.get("referenceType") == "purl"]
        ecos[purls[0]["referenceLocator"].split(":")[1].split("/")[0] if purls else "no-purl"] += 1

    relevant, other_image = [], 0
    for pkg in curated["packages"]:
        m = SECTION_RE.search(pkg.get("comment", ""))
        sec = m.group(1) if m else ""
        if section and not sec.startswith(section):
            other_image += 1
            continue
        relevant.append(pkg)

    seen, unseen = [], []
    for pkg in relevant:
        (seen if matches(pkg["name"], s_names) else unseen).append(pkg)

    print(f"scanner SBOM : {args.scanned.name}")
    print(f"  packages catalogued        : {len(s_pkgs)} ({len(s_names)} distinct names)")
    print("  by ecosystem               : "
          + ", ".join(f"{k} {v}" for k, v in ecos.most_common()))
    print()
    print(f"  curated entries for this image ({section or 'ALL'}): {len(relevant)}"
          + (f"   [{other_image} belong to other images, excluded]" if other_image else ""))
    print(f"    also visible to the scanner : {len(seen)}")
    print(f"    NOT visible to the scanner  : {len(unseen)}")

    copyleft = [p for p in unseen if "offer-source" in p.get("licenseComments", "")]
    print(f"      of those, source-obligated: {len(copyleft)}")
    if copyleft:
        print()
        print("  Copyleft components the scanner cannot see — why both halves exist:")
        for p in copyleft:
            print(f"    - {p['name']}  [{p.get('licenseDeclared','')}]")
    if unseen and not copyleft:
        print("    (none carry a source obligation)")
    print()
    print(f"  combined coverage: {len(s_names)} scanned + {len(unseen)} curated-only "
          f"= {len(s_names) + len(unseen)} distinct components")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
