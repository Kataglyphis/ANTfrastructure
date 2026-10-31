#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
"""Prepare an immutable GPU artifact for checks, without approving it."""

from __future__ import annotations

import argparse
import importlib
import os
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
receipt = importlib.import_module("gpu_artifact_receipt")
staging = importlib.import_module("stage_gpu_artifact")


def prepare(args: argparse.Namespace) -> None:
    """Extract a digest-matched archive and record the pre-check package hashes."""
    identity = {key: getattr(args, key) for key in receipt.IDENTITY if key != "check"}
    receipt.validate_identity({**identity, "check": "before-check"})
    names = receipt.validate_files(args.file)
    output = Path(args.output)
    before = Path(args.before_receipt)
    if os.path.lexists(before) or before.resolve().parent == output.resolve():
        raise ValueError(
            "before-check receipt must be a new file outside the package directory"
        )
    staging.extract_archive(
        Path(args.archive),
        output,
        identity["artifact_digest"].removeprefix("sha256:"),
        names,
        args.max_uncompressed_bytes,
        args.max_compression_ratio,
        None,
    )
    receipt.execute(
        argparse.Namespace(
            **identity,
            check="before-check",
            file=names,
            receipt=str(before),
            directory=str(output),
            operation="create",
        )
    )


def main() -> int:
    """Expose the archive, expected filenames, limits and trusted CI identity."""
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("archive", "output", "before-receipt"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--file", action="append", required=True)
    parser.add_argument("--max-uncompressed-bytes", type=int, required=True)
    parser.add_argument("--max-compression-ratio", type=int, required=True)
    for key in receipt.IDENTITY:
        if key != "check":
            parser.add_argument("--" + key.replace("_", "-"), required=True)
    try:
        prepare(parser.parse_args())
    except (OSError, ValueError, TypeError, RuntimeError, zipfile.BadZipFile) as exc:
        print(f"GPU artifact preparation: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
