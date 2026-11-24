# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Read bounded original files and write fresh payloads; no source authenticity or binary linkage proof."""

from __future__ import annotations

import stat
from pathlib import Path
from typing import Any

SOURCE_ORIGINALS_API = 1


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result = dict(pairs)
    require(len(result) == len(pairs), "Duplicate policy key")
    return result


def plain_parents(path: Path) -> None:
    require(
        path.is_absolute() and ".." not in path.parts,
        "Path must be absolute without traversal",
    )
    for parent in reversed(path.parents):
        if parent.exists() or parent.is_symlink():
            require(
                stat.S_ISDIR(parent.lstat().st_mode),
                "Linked or non-directory parent: " + str(parent),
            )


def original_bytes(
    path: Path, *, max_bytes: int = 1024 * 1024, allow_empty: bool = False
) -> bytes:
    plain_parents(path)
    info = path.lstat()
    require(
        stat.S_ISREG(info.st_mode) and info.st_nlink == 1,
        "Original must be a single regular file: " + str(path),
    )
    require(
        int(not allow_empty) <= info.st_size <= max_bytes,
        "Empty or oversized original: " + str(path),
    )
    with path.open("rb") as stream:
        data = stream.read(max_bytes + 1)
    require(len(data) == info.st_size, "Original size changed: " + str(path))
    return data


def write_originals(destination: Path, payloads: dict[str, bytes]) -> None:
    plain_parents(destination)
    for relative in payloads:
        require(
            not Path(relative).is_absolute()
            and all(part not in ("", ".", "..") for part in relative.split("/")),
            "Invalid original output path",
        )
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.mkdir()
    for relative, data in payloads.items():
        output = destination / relative
        output.parent.mkdir(parents=True, exist_ok=True)
        require(
            output.write_bytes(data) == len(data),
            "Incomplete original write: " + relative,
        )
        require(output.read_bytes() == data, "Staged original differs: " + relative)
