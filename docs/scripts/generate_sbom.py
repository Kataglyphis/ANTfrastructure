#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""Emit an SPDX 2.3 document for the CURATED half of this project's inventory.

Why a second SBOM path exists
-----------------------------
`syft` (or any image scanner) catalogues components that carry package
METADATA: dpkg/apt entries, Python site-packages, npm, Go and Rust binaries.
It cannot see a C/C++ library built from source into `/opt` -- ONNX Runtime,
OpenCV, FFmpeg, GStreamer, libcamera leave no manifest behind. Those are
precisely the components under copyleft licences here, so an image scan alone
would produce an SBOM that silently omits every entry carrying a
corresponding-source obligation.

So the two halves are complementary and both are published:

  * this script -- the curated, source-built components, with their licences,
    their upstream revisions and their source pointers, straight from
    `deps.json` + `versions.env`;
  * `.github/workflows/sbom.yml` -- `syft` against the published image, for the
    thousands of apt/pip components no human can maintain by hand.

Consumers who need one document can merge them; the two are deliberately kept
distinguishable by `creationInfo.creators` so it stays obvious which half a
package came from.

Usage:
    python docs/scripts/generate_sbom.py --write        # write out/sbom/*.spdx.json
    python docs/scripts/generate_sbom.py --check        # fail if it would change
    python docs/scripts/generate_sbom.py --stdout       # print, write nothing

Deliberately dependency-free: SPDX 2.3 JSON is plain JSON, and this must run in
the pre-commit hook and in CI without installing anything.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from deps_table import load_deps_metadata, resolve_dep_version  # noqa: E402
import license_obligations as lo  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
VERSIONS_ENV = REPO_ROOT / "linux/scripts/01-core/versions.env"
OUT_DIR = REPO_ROOT / "docs/deps"
OUT_FILE = OUT_DIR / "sbom-curated.spdx.json"

SPDX_VERSION = "SPDX-2.3"
DOC_NAME = "ContainerHub-curated"

# SPDX requires any non-listed licence id to be declared. Ours are the two
# deliberate coarse buckets -- see license_obligations.py for why they exist.
EXTRACTED = {
    "LicenseRef-Proprietary-EULA": (
        "Proprietary vendor EULA (NVIDIA CUDA/cuDNN/TensorRT, Microsoft Visual Studio Build "
        "Tools and Windows base images). Redistribution is governed by the vendor's terms, "
        "not by an open-source grant."
    ),
    "LicenseRef-Distro-Bundle": (
        "A distribution or tool bundle comprising many packages under many licences (an Ubuntu "
        "base image, a TeX Live installation, a scoop tool set). Per-package licence texts "
        "travel inside the image itself; this id marks the bundle rather than asserting a "
        "single licence over it."
    ),
}


def parse_versions_env() -> dict[str, str]:
    out: dict[str, str] = {}
    for line in VERSIONS_ENV.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, _, v = s.partition("=")
        out[k.strip()] = v.strip()
    return out


def spdx_id(*parts: str) -> str:
    """SPDXID must match [a-zA-Z0-9.-]+ -- component names here do not."""
    raw = "-".join(parts)
    slug = re.sub(r"[^A-Za-z0-9.-]+", "-", raw).strip("-")
    # Names collide once punctuation is stripped ("FFmpeg" in two sections), so
    # a short digest of the full raw string keeps every SPDXID unique.
    digest = hashlib.sha256(raw.encode("utf-8")).hexdigest()[:8]
    return f"SPDXRef-Package-{slug[:60]}-{digest}"


def build_document(versions: dict[str, str]) -> dict:
    metadata = load_deps_metadata()
    packages: list[dict] = []
    relationships: list[dict] = []

    for section in metadata["sections"]:
        for subsection in section["subsections"]:
            for entry in subsection["entries"]:
                name = entry["name"]
                version = resolve_dep_version(entry, versions)
                spdx_expr = entry["spdx"]
                src = entry.get("source") or {}
                download = src.get("url") or entry.get("url") or "NOASSERTION"

                pkg = {
                    "SPDXID": spdx_id(section["title"], name),
                    "name": name,
                    "versionInfo": version if version != "—" else "NOASSERTION",
                    "downloadLocation": download,
                    "filesAnalyzed": False,
                    "supplier": "NOASSERTION",
                    "licenseDeclared": spdx_expr,
                    "licenseConcluded": spdx_expr,
                    "copyrightText": "NOASSERTION",
                    "comment": (
                        f"Image section: {section['title']} / {subsection['title']}"
                        + (f" ({subsection['dockerfile']})" if subsection.get("dockerfile") else "")
                    ),
                }

                notes: list[str] = []
                obligations = lo.obligations_for(spdx_expr)
                notes.append("Obligations: " + ", ".join(obligations) if obligations else
                             "Obligations: none")
                if lo.requires_source(spdx_expr):
                    ref = src.get("ref") or versions.get(src.get("ref_var", ""), "")
                    notes.append(
                        "Corresponding source required. Upstream: "
                        f"{src.get('url', 'NOASSERTION')}"
                        + (f" at {ref}" if ref else "")
                    )
                    if src.get("build_flags"):
                        notes.append(f"Build configuration: {src['build_flags']}")
                if src.get("patches"):
                    notes.append("Patched in this repository: " + ", ".join(src["patches"]))
                if entry.get("modified"):
                    notes.append("MODIFIED before redistribution: "
                                 + entry["modified"].get("note", ""))
                pkg["licenseComments"] = " | ".join(notes)

                packages.append(pkg)
                relationships.append({
                    "spdxElementId": "SPDXRef-DOCUMENT",
                    "relationshipType": "DESCRIBES",
                    "relatedSpdxElement": pkg["SPDXID"],
                })

    return {
        "spdxVersion": SPDX_VERSION,
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": DOC_NAME,
        # No timestamp and no random namespace on purpose: the document must be
        # byte-reproducible so `--check` can gate it. The image-scan SBOM in CI
        # carries the build-time provenance instead.
        "documentNamespace": (
            "https://github.com/Kataglyphis/ContainerHub/spdx/curated"
        ),
        "creationInfo": {
            "created": "1970-01-01T00:00:00Z",
            "creators": [
                "Tool: docs/scripts/generate_sbom.py",
                "Organization: Kataglyphis",
            ],
            "comment": (
                "CURATED half of the inventory: components built from source, which an image "
                "scanner cannot see because they carry no package metadata. The scanner half "
                "is produced by .github/workflows/sbom.yml. The fixed timestamp keeps this "
                "document reproducible so it can be gated in CI."
            ),
        },
        "hasExtractedLicensingInfos": [
            {"licenseId": lid, "extractedText": text, "name": lid}
            for lid, text in sorted(EXTRACTED.items())
        ],
        "packages": packages,
        "relationships": relationships,
    }


def render(doc: dict) -> str:
    return json.dumps(doc, indent=2, ensure_ascii=False, sort_keys=False) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description="Emit the curated SPDX SBOM.")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--stdout", action="store_true")
    args = ap.parse_args()

    content = render(build_document(parse_versions_env()))

    if args.stdout:
        sys.stdout.write(content)
        return 0
    if args.write:
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        OUT_FILE.write_text(content, encoding="utf-8", newline="\n")
        pkgs = len(json.loads(content)["packages"])
        print(f"Written: {OUT_FILE.relative_to(REPO_ROOT)} ({pkgs} packages)")
        return 0

    # Default is --check, matching the other generators in this directory.
    if OUT_FILE.exists() and OUT_FILE.read_text(encoding="utf-8") == content:
        print(f"Curated SBOM is up to date ({len(json.loads(content)['packages'])} packages).")
        return 0
    print("Curated SBOM is out of date.", file=sys.stderr)
    print("Run: python docs/scripts/generate_sbom.py --write", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
