#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
"""Resolve one current-run producer receipt to GPU action inputs."""

from __future__ import annotations

import argparse
import importlib
import os
import re
import sys
from pathlib import Path
from typing import TypedDict

sys.path.insert(0, str(Path(__file__).resolve().parent))
receipt = importlib.import_module("gpu_artifact_receipt")


class ProducerInputs(TypedDict):
    """The independently checked upload identity and its exact package names."""

    artifact_id: str
    artifact_digest: str
    files: list[str]


def resolve(
    path: Path,
    platform: str,
    vendor: str,
    arch: str,
    artifact_id: str,
    artifact_digest: str,
    package_layout: str = "",
) -> ProducerInputs:
    """Check the receipt against the caller and return its identity and package names."""
    if platform not in {"linux", "windows"}:
        raise ValueError("unsupported GPU package platform")
    data = receipt.read_receipt(path)
    identity = data["identity"]
    receipt.validate_identity(identity)
    expected = {
        "repository": os.environ["GITHUB_REPOSITORY"],
        "revision": os.environ["GITHUB_SHA"],
        "run_id": os.environ["GITHUB_RUN_ID"],
        "run_attempt": os.environ["GITHUB_RUN_ATTEMPT"],
        "platform": platform,
        "vendor": vendor,
        "arch": arch,
        "check": "producer-verified",
        "artifact_id": artifact_id,
        "artifact_digest": artifact_digest.removeprefix("sha256:"),
    }
    if any(identity[key] != value for key, value in expected.items()):
        raise ValueError("producer receipt does not match this run or GPU tuple")
    hashes = data["files"]
    names = receipt.validate_files(list(hashes))
    if any(
        not isinstance(value, str) or not receipt.SHA256.fullmatch(value)
        for value in hashes.values()
    ):
        raise ValueError("invalid producer package hash")
    validate_layout(platform, package_layout, names, vendor)
    return {
        "artifact_id": identity["artifact_id"],
        "artifact_digest": identity["artifact_digest"],
        "files": names,
    }


def validate_layout(platform: str, layout: str, names: list[str], vendor: str) -> None:
    """Enforce explicit Windows package shapes while retaining the Linux contract."""
    if platform == "linux":
        if layout not in {"", "linux"}:
            raise ValueError("invalid Linux package layout")
        extensions = (".deb", ".tar.gz", ".AppImage")
        if len(names) != len(extensions) or any(
            sum(name.endswith(ext) for name in names) != 1 for ext in extensions
        ):
            raise ValueError("expected one DEB, tarball and AppImage")
        return
    if layout == "zip":
        if len(names) != 1 or not names[0].endswith(".zip") or len(names[0]) == 4:
            raise ValueError("expected one Windows ZIP")
        return
    if layout == "accelerantgine":
        validate_accelerantgine_layout(names, vendor)
        return
    if layout not in {"installers", "zip-installers"}:
        raise ValueError("Windows packages require an explicit supported layout")
    msi = [name for name in names if name.endswith(".msi")]
    if len(msi) != 1:
        raise ValueError("expected one Windows MSI")
    stem = msi[0][:-4]
    if not stem:
        raise ValueError("empty Windows package stem")
    expected = {msi[0], stem + ".msix"}
    if layout == "zip-installers":
        expected.add(stem + ".zip")
    certificates = {stem + "-testcert.cer", stem + "-test-signing.cer"}
    if len(set(names) - expected) != 1 or not (set(names) - expected) <= certificates:
        raise ValueError("expected the matching Windows test certificate")
    if not expected <= set(names):
        raise ValueError("Windows package names do not share the MSI stem")


def validate_accelerantgine_layout(names: list[str], vendor: str) -> None:
    """Match CPack ZIP/MSI to the differently named four-component MSIX."""
    pattern = rf"AccelerANTgine-(\d+(?:\.\d+){{0,3}})-Release-x86_64-gpu-{vendor}\.zip"
    matches = [re.fullmatch(pattern, name) for name in names]
    matches = [match for match in matches if match is not None]
    if len(matches) != 1:
        raise ValueError("expected one matching AccelerANTgine GPU ZIP")
    version = matches[0].group(1).split(".")
    version.extend(["0"] * (4 - len(version)))
    cpack_stem = matches[0].group(0)[:-4]
    msix_stem = f"AccelerANTgine_{'.'.join(version)}_x64-gpu-{vendor}"
    expected = {cpack_stem + ".zip", cpack_stem + ".msi", msix_stem + ".msix"}
    optional = {
        stem + suffix
        for stem in (cpack_stem, msix_stem)
        for suffix in (".cer", "-testcert.cer", "-test-signing.cer")
    }
    extra = set(names) - expected
    if not expected <= set(names) or len(extra) > 1 or not extra <= optional:
        raise ValueError("AccelerANTgine GPU package names or certificate do not match")


def main() -> int:
    """Write only validated identity and portable filenames to GITHUB_OUTPUT."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipt", type=Path)
    for name in ("platform", "vendor", "arch", "artifact-id", "artifact-digest"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--package-layout", default="")
    args = parser.parse_args()
    try:
        result = resolve(
            args.receipt,
            args.platform,
            args.vendor,
            args.arch,
            args.artifact_id,
            args.artifact_digest,
            args.package_layout,
        )
        output = Path(os.environ["GITHUB_OUTPUT"])
        with output.open("a", encoding="utf-8") as stream:
            stream.write(
                f"artifact_id={result['artifact_id']}\nartifact_digest={result['artifact_digest']}\n"
            )
            stream.write(
                "files<<GPU_PACKAGE_FILES\n"
                + "\n".join(result["files"])
                + "\nGPU_PACKAGE_FILES\n"
            )
    except (OSError, KeyError, TypeError, ValueError) as exc:
        print(f"GPU producer receipt: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
