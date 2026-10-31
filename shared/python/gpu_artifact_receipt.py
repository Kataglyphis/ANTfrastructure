#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
"""Bind named GPU packages to a caller-asserted check and immutable CI identity."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

SHA256 = re.compile(r"^[0-9a-f]{64}$")
REVISION = re.compile(r"^[0-9a-f]{40}$")
REPOSITORY = re.compile(r"^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$")
CHECK = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
FILE = re.compile(r'^[^/\\<>:"|?*\x00-\x1f]+$')
DEVICES = {
    ("linux", "x64", "amd"),
    ("linux", "x64", "nvidia"),
    ("linux", "arm64", "nvidia"),
    ("windows", "x64", "amd"),
    ("windows", "x64", "nvidia"),
}
IDENTITY = (
    "repository",
    "revision",
    "run_id",
    "run_attempt",
    "artifact_id",
    "artifact_digest",
    "platform",
    "arch",
    "vendor",
    "check",
)


def valid_filename(name: str) -> bool:
    """Require a single portable filename, without Windows aliases."""
    stem = name.split(".", 1)[0].rstrip(" ").upper()
    reserved = {
        "CON",
        "PRN",
        "AUX",
        "NUL",
        "CONIN$",
        "CONOUT$",
        *(f"COM{i}" for i in range(1, 10)),
        *(f"LPT{i}" for i in range(1, 10)),
        *(f"{prefix}{digit}" for prefix in ("COM", "LPT") for digit in "¹²³"),
    }
    return (
        bool(FILE.fullmatch(name))
        and name not in {".", ".."}
        and not name.endswith((".", " "))
        and stem not in reserved
    )


def validate_files(names: list[str]) -> list[str]:
    """Validate the caller's expected package names before accessing the filesystem."""
    if not names or any(not valid_filename(name) for name in names):
        raise ValueError("expected files must be nonempty portable filenames")
    if len({name.casefold() for name in names}) != len(names):
        raise ValueError("duplicate expected filenames")
    return sorted(names)


def validate_identity(identity: dict[str, str]) -> None:
    """Refuse malformed or unsupported CI identities and device combinations."""
    if not REPOSITORY.fullmatch(identity["repository"]) or identity["repository"].split(
        "/"
    )[1] in {".", ".."}:
        raise ValueError("invalid repository")
    if not REVISION.fullmatch(identity["revision"]):
        raise ValueError("revision must be a full lowercase commit SHA")
    for field in ("run_id", "run_attempt", "artifact_id"):
        if not re.fullmatch(r"[1-9][0-9]*", identity[field]):
            raise ValueError(f"invalid {field}")
    digest = identity["artifact_digest"].removeprefix("sha256:")
    if not SHA256.fullmatch(digest):
        raise ValueError("invalid artifact digest")
    identity["artifact_digest"] = digest
    if (identity["platform"], identity["arch"], identity["vendor"]) not in DEVICES:
        raise ValueError(
            "unsupported GPU platform, architecture and vendor combination"
        )
    if not CHECK.fullmatch(identity["check"]):
        raise ValueError("invalid check identity")


def digest_file(path: Path) -> str:
    """Hash the whole package without loading it into memory."""
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def is_link(path: Path) -> bool:
    """Reject POSIX links and Windows reparse points, including junctions."""
    return path.is_symlink() or bool(
        getattr(path.lstat(), "st_file_attributes", 0) & 0x400
    )


def package_hashes(directory: Path, names: list[str]) -> dict[str, str]:
    """Require exactly the requested regular files and return their hashes."""
    if is_link(directory) or not directory.is_dir():
        raise ValueError("package directory must be a real directory")
    entries = list(directory.iterdir())
    if {entry.name for entry in entries} != set(names) or len(entries) != len(names):
        raise ValueError(
            "package directory does not contain exactly the expected files"
        )
    if any(is_link(entry) or not entry.is_file() for entry in entries):
        raise ValueError("packages must be regular files, not links or directories")
    return {name: digest_file(directory / name) for name in names}


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """Reject duplicate JSON keys instead of silently accepting the last one."""
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_receipt(path: Path) -> dict[str, Any]:
    """Read an untrusted receipt with strict schema and duplicate-key checks."""
    data = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    if not isinstance(data, dict) or set(data) != {
        "schema_version",
        "identity",
        "status",
        "files",
    }:
        raise ValueError("invalid receipt schema")
    if (
        type(data["schema_version"]) is not int
        or data["schema_version"] != 1
        or data["status"] != "passed"
    ):
        raise ValueError("receipt is not a passed schema version 1 check")
    if not isinstance(data["identity"], dict) or set(data["identity"]) != set(IDENTITY):
        raise ValueError("invalid receipt identity")
    if not isinstance(data["files"], dict):
        raise TypeError("invalid receipt file manifest")
    return data


def execute(args: argparse.Namespace) -> None:
    """Create a new receipt or check all expected identity and file bytes."""
    identity = {key: getattr(args, key) for key in IDENTITY}
    validate_identity(identity)
    names = validate_files(args.file)
    receipt = Path(args.receipt)
    directory = Path(args.directory)
    if receipt.resolve().parent == directory.resolve():
        raise ValueError("receipt must be outside the package directory")
    hashes = package_hashes(directory, names)
    if args.operation == "create":
        data = {
            "schema_version": 1,
            "identity": identity,
            "status": "passed",
            "files": hashes,
        }
        with receipt.open("x", encoding="utf-8", newline="\n") as stream:
            json.dump(data, stream, indent=2, sort_keys=True)
            stream.write("\n")
    else:
        data = read_receipt(receipt)
        if data["identity"] != identity:
            raise ValueError("receipt identity does not match the expected check")
        if data["files"] != hashes:
            raise ValueError("receipt package names or hashes do not match")


def main() -> int:
    """Expose the same explicit identity arguments for receipt creation and verification."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("create", "verify"))
    parser.add_argument("--directory", required=True)
    parser.add_argument("--receipt", required=True)
    parser.add_argument(
        "--file",
        action="append",
        required=True,
        help="exact expected filename; repeat for each package",
    )
    for key in IDENTITY:
        parser.add_argument("--" + key.replace("_", "-"), required=True)
    try:
        execute(parser.parse_args())
    except (OSError, ValueError, TypeError) as exc:
        print(f"GPU receipt: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
