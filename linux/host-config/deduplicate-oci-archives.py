#!/usr/bin/env python3
"""Preview or apply digest-bound archive deduplication; supplied authorization is not authenticated."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("preview", "apply"))
    parser.add_argument("--review", type=Path, required=True)
    parser.add_argument("--expected-sha256", required=True)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--root", type=Path)
    parser.add_argument("--receipt-root", type=Path, action="append")
    parser.add_argument("--authorization", type=Path)
    parser.add_argument("--engine", default="nerdctl")
    args = parser.parse_args()
    scripts = Path(__file__).resolve().parents[1] / "scripts"
    sys.path[:0] = [str(scripts), str(scripts / "local-proof")]
    from oci_archive_dedup import apply_plan, make_plan

    if args.action == "preview":
        if not args.root or not args.receipt_root or not args.authorization:
            parser.error("Preview requires root, receipt roots and authorization")
        result = make_plan(
            args.review,
            args.expected_sha256,
            args.root,
            args.receipt_root,
            args.directory,
            args.authorization,
            args.engine,
        )
    else:
        result = apply_plan(
            args.review, args.expected_sha256, args.directory, args.engine
        )
    print(
        json.dumps(
            {
                key: value
                for key, value in result.items()
                if key
                not in {
                    "groups",
                    "protected_receipt_sha256",
                    "protected_identity_numbers",
                }
            }
        )
    )


if __name__ == "__main__":
    try:
        main()
    except (
        AssertionError,
        OSError,
        ValueError,
        KeyError,
        RuntimeError,
        subprocess.SubprocessError,
    ) as error:
        raise SystemExit(f"OCI deduplication refused: {error}") from error
