#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
"""Verify selected packaged files against a data lock without downloading."""

from __future__ import annotations

import argparse
import runpy
import sys
from pathlib import Path


def is_link(path: Path) -> bool:
    """Reject symbolic links and Windows reparse points such as junctions."""
    return path.is_symlink() or bool(
        getattr(path.lstat(), "st_file_attributes", 0) & 0x400
    )


def verify(
    root: Path, directory: Path, lock: Path, fetcher: Path, names: list[str]
) -> None:
    """Require locked file bytes under a package root with no symlink traversal."""
    if not names or len(names) != len({name.casefold() for name in names}):
        raise ValueError("expected file names must be nonempty and unique")
    if any(
        not name or name in {".", ".."} or "/" in name or "\\" in name for name in names
    ):
        raise ValueError("expected file names must be plain names")
    root = root.absolute()
    directory = directory.absolute()
    if not root.is_dir() or is_link(root):
        raise ValueError("package root must be a real directory")
    try:
        relative = directory.relative_to(root)
    except ValueError as error:
        raise ValueError("file directory escapes the package root") from error
    current = root
    for part in relative.parts:
        if part in {".", ".."}:
            raise ValueError("file directory escapes the package root")
        current = current / part
        if not current.is_dir() or is_link(current):
            raise ValueError("file directory is missing or linked")
    if not directory.resolve().is_relative_to(root.resolve()):
        raise ValueError("file directory escapes the package root")
    api = runpy.run_path(str(fetcher))
    try:
        rows = api["read_lock"](lock)
        expected = {name: digest for digest, name, _ in rows}
    except Exception as error:
        raise ValueError(f"cannot read data lock: {error}") from error
    if not set(names).issubset(expected):
        raise ValueError("data lock is missing a required file")
    for name in names:
        path = directory / name
        if (
            not path.is_file()
            or is_link(path)
            or not api["matches"](path, expected[name])
        ):
            raise ValueError(f"locked file is missing, linked or changed: {path}")


def main() -> int:
    """Expose the package root, data lock and exact required file names."""
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("root", "directory", "lock", "fetcher"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--file", action="append", required=True)
    args = parser.parse_args()
    try:
        verify(args.root, args.directory, args.lock, args.fetcher, args.file)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Locked package file verification failed: {error}", file=sys.stderr)
        return 1
    print("Packaged files match the data lock")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
