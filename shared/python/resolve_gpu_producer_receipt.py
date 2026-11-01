#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
"""Resolve one current-run producer receipt to GPU action inputs."""

from __future__ import annotations

import argparse
import importlib
import os
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
) -> ProducerInputs:
    """Check the receipt against the caller and return its identity and package names."""
    if platform != "linux":
        raise ValueError("GPU producer resolution supports Linux packages only")
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
    extensions = (".deb", ".tar.gz", ".AppImage")
    if len(names) != len(extensions) or any(
        sum(name.endswith(ext) for name in names) != 1 for ext in extensions
    ):
        raise ValueError(
            "producer receipt does not contain exactly the required package formats"
        )
    return {
        "artifact_id": identity["artifact_id"],
        "artifact_digest": identity["artifact_digest"],
        "files": names,
    }


def main() -> int:
    """Write only validated identity and portable filenames to GITHUB_OUTPUT."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipt", type=Path)
    for name in ("platform", "vendor", "arch", "artifact-id", "artifact-digest"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    try:
        result = resolve(
            args.receipt,
            args.platform,
            args.vendor,
            args.arch,
            args.artifact_id,
            args.artifact_digest,
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
