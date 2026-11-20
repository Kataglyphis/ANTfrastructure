#!/usr/bin/env python3
"""Restore a digest-selected parent snapshot; no source authentication, recursive dependencies or build acceptance."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import runpy
import subprocess
from pathlib import Path
from typing import Any

from source_ci.common import require, save, timestamp

PRESERVER = runpy.run_path(
    str(Path(__file__).with_name("preserve-consumer-sources.py"))
)
INPUTS = {"base.bundle", "working.patch", "working-index.bin", "versioned-files.json"}


def archive_input(archive: Path, name: str, digest: str) -> bytes:
    data = (archive / name).read_bytes()
    require(
        hashlib.sha256(data).hexdigest() == digest,
        "Archive input digest differs: " + name,
    )
    return data


def read_archive(archive: Path, expected: str) -> dict[str, Any]:
    manifest = archive / "archive.json"
    require(
        hashlib.sha256(manifest.read_bytes()).hexdigest() == expected,
        "Archive manifest digest differs",
    )
    spec = json.loads(manifest.read_text())
    require(
        spec["schema"] == 1 and type(spec["shallow"]) is bool,
        "Unsupported archive schema",
    )
    require(
        re.fullmatch(r"[0-9a-f]{40}", spec["base"]) is not None, "Invalid archive base"
    )
    require(
        re.fullmatch(
            r"https://github.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git", spec["origin"]
        )
        is not None,
        "Invalid archive origin",
    )
    names = INPUTS | ({"original-shallow.bin"} if spec["shallow"] else set())
    require(set(spec["files"]) == names, "Archive input set differs")
    for name, digest in spec["files"].items():
        archive_input(archive, name, digest)
    return spec


def validate_metadata(destination: Path, files: dict[str, Any]) -> None:
    before = PRESERVER["working_files"](destination)
    require(
        isinstance(files, dict) and set(files) == set(before),
        "Archive metadata paths differ",
    )
    for name, row in files.items():
        require(
            row["git_mode"] == before[name]["git_mode"], "Archive metadata kinds differ"
        )
        if row["git_mode"] in {"100644", "100755"}:
            mode = row["mode"]
            require(
                type(mode) is int and 0 <= mode <= 0o7777,
                "Archive metadata mode differs",
            )


def restore_archive(
    archive: Path, expected: str, destination: Path, receipt: Path
) -> dict[str, Any]:
    archive = archive.resolve(strict=True)
    require(
        not destination.exists() and not destination.is_symlink(),
        "Preserve existing archive destination",
    )
    destination, receipt = destination.resolve(), receipt.resolve()
    require(
        not destination.is_relative_to(archive)
        and not archive.is_relative_to(destination),
        "Archive destination overlaps inputs",
    )
    require(
        not receipt.exists()
        and not receipt.is_relative_to(destination)
        and not receipt.is_relative_to(archive),
        "Preserve existing or overlapping archive receipt",
    )
    spec = read_archive(archive, expected)
    expected_index = archive_input(
        archive, "working-index.bin", spec["files"]["working-index.bin"]
    )
    files = json.loads(
        archive_input(
            archive, "versioned-files.json", spec["files"]["versioned-files.json"]
        )
    )
    subprocess.run(
        [
            "git",
            "clone",
            "--no-checkout",
            "--",
            str(archive / "base.bundle"),
            str(destination),
        ],
        capture_output=True,
        check=True,
        timeout=180,
    )
    if spec["shallow"]:
        (destination / ".git/shallow").write_bytes(
            archive_input(
                archive, "original-shallow.bin", spec["files"]["original-shallow.bin"]
            )
        )
    PRESERVER["git"](destination, "checkout", "--detach", spec["base"])
    PRESERVER["git"](destination, "apply", "--index", str(archive / "working.patch"))
    validate_metadata(destination, files)
    PRESERVER["restore_working_modes"](destination, files)
    PRESERVER["git"](destination, "remote", "set-url", "origin", spec["origin"])
    head, index, actual = PRESERVER["working_snapshot"](destination)
    require(head == spec["base"], "Restored archive base differs")
    require(index == expected_index, "Restored archive index differs")
    require(actual == files, "Restored archive bytes, modes or links differ")
    PRESERVER["verify_objects"](destination)
    read_archive(archive, expected)
    record = {
        "status": "restored-exact-parent-archive-only",
        "observed_at": timestamp(),
        "source": str(destination),
        "archive": str(archive),
        "archive_manifest_sha256": expected,
        "base": head,
        "index_sha256": hashlib.sha256(index).hexdigest(),
        "versioned_entries": len(files),
        "original_shallow_metadata_restored": spec["shallow"],
        "full_Git_history_claimed": False,
        "recursive_dependencies_restored": False,
        "scope": __doc__,
    }
    save(receipt, record)
    return record


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--expected-manifest-sha256", required=True)
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = restore_archive(
            args.archive, args.expected_manifest_sha256, args.destination, args.receipt
        )
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        subprocess.SubprocessError,
    ) as error:
        parser.exit(1, f"FAIL: {error}\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
