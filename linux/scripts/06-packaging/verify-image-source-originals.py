#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Check exact staged source-original members; no record authentication, binary association or complete licence/source proof."""

from __future__ import annotations

import argparse
import json
import re
import runpy
import subprocess
import sys
from pathlib import Path

STAGER = Path(__file__).with_name("stage-image-source-originals.py")
BINARY = Path(__file__).parents[1] / "verify_package_binary.py"
_originals = runpy.run_path(str(STAGER))
_binary = runpy.run_path(str(BINARY))
for _module, _api, _names in (
    (
        _originals,
        "IMAGE_SOURCE_ORIGINALS_API",
        ("read_json", "original_bytes", "exact_tree", "sha", "require"),
    ),
    (_binary, "PACKAGE_BINARY_EMPTY_API", ("exact_name",)),
):
    if _module.get(_api) != 1:
        raise ValueError("Unsupported source-original verification companion: " + _api)
    for _name in _names:
        if not callable(_module.get(_name)):
            raise TypeError("Missing source-original verification export: " + _name)
require = _originals["require"]


def original_rules(root: Path, prefix: str) -> list[tuple[str, Path, bool]]:
    prefix = _binary["exact_name"](prefix)
    record = _originals["read_json"](root / "source-originals.json")
    require(
        record.get("schema") == 1
        and record.get("status") == "selected-image-source-originals-preserved",
        "Invalid source-original record identity",
    )
    require(
        record.get("binary_linkage_or_complete_license_source_closure_proven") is False,
        "Source-original record exceeds selected scope",
    )
    files = record.get("files")
    require(
        isinstance(files, dict) and bool(files),
        "Empty or invalid source-original file record",
    )
    rules = []
    for relative, expected in sorted(files.items()):
        name = _binary["exact_name"](relative)
        source = root / name
        patch = (
            re.fullmatch(
                r"gstreamer-source-build/(?:monorepo|rust-monorepo|rust-standalone)/source\.patch",
                name,
            )
            is not None
        )
        data = _originals["original_bytes"](
            source,
            max_bytes=8 * 1024 * 1024 if patch else 1024 * 1024,
            allow_empty=patch,
        )
        require(
            isinstance(expected, dict)
            and type(expected.get("bytes")) is int
            and expected == {"sha256": _originals["sha"](data), "bytes": len(data)},
            "Staged source-original record differs: " + name,
        )
        rules.append((prefix + "/" + name, source, not data))
    _originals["exact_tree"](root, set(files) | {"source-originals.json"})
    rules.append(
        (prefix + "/source-originals.json", root / "source-originals.json", False)
    )
    return rules


def verify(args: argparse.Namespace) -> int:
    rules = original_rules(args.originals.absolute(), args.prefix)
    if args.appimage_arch is not None:
        native = Path(__file__).with_name("verify-native-appimage-binary.sh")
        for member, source, empty in rules:
            command = ["bash", str(native)]
            if empty:
                command.append("--allow-empty-source")
            command.extend((str(args.package), args.appimage_arch, member, str(source)))
            result = subprocess.run(command, check=False)
            if result.returncode:
                return result.returncode
    else:
        command = [sys.executable, "-B", str(BINARY), str(args.package)]
        for member, source, empty in rules:
            command.extend(("--require", member + "=" + str(source)))
            if empty:
                command.extend(("--allow-empty", member))
        result = subprocess.run(command, check=False)
        if result.returncode:
            return result.returncode
    print(
        json.dumps(
            {
                "status": "selected-source-original-package-bytes-match",
                "members": len(rules),
            }
        )
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--originals", type=Path, required=True)
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--appimage-arch")
    args = parser.parse_args()
    try:
        return verify(args)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(
            1, "Source-original package verification refused: " + str(error) + "\n"
        )


if __name__ == "__main__":
    raise SystemExit(main())
