#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Stage ONNX Runtime wheel notices after byte-matching the packaged native ELFs.

Each supplied library must match its uniquely named wheel component, either as-is
or after stripping the wheel entry with the selected target-architecture tool.
The check does not enumerate other native libraries or their legal obligations.
"""
from __future__ import annotations

import argparse
import hashlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

from ort_census_probe import file_sha

MAX_LIBRARY_BYTES = 256 * 1024 * 1024
MAX_TEXT_BYTES = 16 * 1024 * 1024
TEXTS = ("LICENSE", "ThirdPartyNotices.txt")
ORT_LIBRARY = re.compile(r"^(libonnxruntime(?:_providers_[a-zA-Z0-9_]+)?\.so)(?:\.\d+)*$")


def elf_target(header: bytes) -> tuple[int, int, int]:
    """Validate the ELF identity before invoking a target-specific strip tool."""
    if len(header) < 20 or header[:4] != b"\x7fELF" or header[4] not in (1, 2) or header[5] not in (1, 2):
        raise ValueError("invalid ELF identity")
    order = "little" if header[5] == 1 else "big"
    machine = int.from_bytes(header[18:20], order)
    if machine == 0:
        raise ValueError("invalid ELF machine")
    return header[4], header[5], machine


def entry_bytes(archive: zipfile.ZipFile, name: str, limit: int) -> bytes | None:
    """Reject duplicate, linked, empty or excessively large expected entries."""
    entries = [entry for entry in archive.infolist() if entry.filename == name]
    if not entries:
        return None
    if len(entries) != 1:
        raise ValueError(f"duplicate wheel entry: {name}")
    entry = entries[0]
    if entry.is_dir() or stat.S_ISLNK(entry.external_attr >> 16) or not 0 < entry.file_size <= limit:
        raise ValueError(f"invalid wheel entry: {name}")
    with archive.open(entry) as stream:
        content = stream.read(limit + 1)
    if len(content) != entry.file_size or len(content) > limit:
        raise ValueError(f"invalid wheel entry size: {name}")
    return content


def wheel_has_library(archive: zipfile.ZipFile, library: Path, strip: str, scratch: Path) -> bool:
    """Require byte identity, not just a release version or a source marker."""
    component = ORT_LIBRARY.fullmatch(library.resolve(strict=True).name)
    if component is None:
        raise ValueError(f"invalid ONNX Runtime library name: {library}")
    prefix = "onnxruntime/capi/"
    entries = [entry.filename for entry in archive.infolist() if entry.filename.startswith(prefix)
               and (match := ORT_LIBRARY.fullmatch(entry.filename[len(prefix):]))
               and match.group(1) == component.group(1)]
    if not entries:
        return False
    if len(entries) != 1:
        raise ValueError(f"ambiguous wheel component: {component.group(1)}")
    content = entry_bytes(archive, entries[0], MAX_LIBRARY_BYTES)
    if content is None:
        raise ValueError(f"missing wheel component: {entries[0]}")
    with library.open("rb") as stream:
        native_target = elf_target(stream.read(20))
    if elf_target(content[:20]) != native_target:
        return False
    expected = file_sha(str(library))
    if hashlib.sha256(content).hexdigest() == expected:
        return True
    copied = scratch / component.group(1)
    copied.write_bytes(content)
    subprocess.run([strip, "--strip-all", "--", str(copied)], check=True, capture_output=True)
    return file_sha(str(copied)) == expected


def selected_wheel(directory: Path, libraries: list[Path], strip: str, scratch: Path) -> Path:
    """One wheel must independently match every requested delivered library."""
    if not directory.is_dir():
        raise ValueError(f"wheel directory is missing: {directory}")
    matches = []
    for wheel in sorted(directory.glob("onnxruntime*.whl")):
        if wheel.name.startswith("onnxruntime_genai-"):
            continue
        with zipfile.ZipFile(wheel) as archive:
            if all(wheel_has_library(archive, library, strip, scratch) for library in libraries):
                matches.append(wheel)
    if len(matches) != 1:
        raise ValueError(f"expected one wheel matching every native library; found {len(matches)}")
    return matches[0]


def read_texts(wheel: Path) -> dict[str, bytes]:
    """Read original notice bytes, rejecting missing, blank or invalid text."""
    texts = {}
    with zipfile.ZipFile(wheel) as archive:
        for name in TEXTS:
            content = entry_bytes(archive, f"onnxruntime/{name}", MAX_TEXT_BYTES)
            if content is None or b"\0" in content or not content.decode("utf-8").strip():
                raise ValueError(f"wheel license text is missing or blank: {name}")
            texts[name] = content
    return texts


def write_texts(destination: Path, texts: dict[str, bytes]) -> Path:
    """Reuse exact existing texts or create a directory without stale overwrites."""
    parent = destination / "licenses"
    for path in (destination, parent):
        if path.is_symlink():
            raise ValueError(f"license destination is a symlink: {path}")
    if not destination.is_dir():
        raise ValueError(f"bundle destination is not a directory: {destination}")
    parent.mkdir(exist_ok=True)
    output = parent / "onnxruntime"
    if output.is_symlink():
        raise ValueError(f"license destination is a symlink: {output}")
    if output.exists():
        for name, content in texts.items():
            target = output / name
            if target.is_symlink() or not target.is_file() or target.read_bytes() != content:
                raise ValueError(f"existing license does not match wheel: {target}")
        return output
    output.mkdir()
    try:
        for name, content in texts.items():
            (output / name).write_bytes(content)
    except OSError:
        shutil.rmtree(output)
        raise
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wheel-dir", type=Path, required=True)
    parser.add_argument("--library", type=Path, action="append", required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--strip", required=True, help="target-compatible strip executable")
    args = parser.parse_args()
    try:
        if not shutil.which(args.strip):
            raise ValueError(f"strip executable not found: {args.strip}")
        for library in args.library:
            if not library.is_file() or not ORT_LIBRARY.fullmatch(library.resolve().name):
                raise ValueError(f"not a native ONNX Runtime library: {library}")
        with tempfile.TemporaryDirectory(prefix="ort-wheel-license-") as temp:
            wheel = selected_wheel(args.wheel_dir, args.library, args.strip, Path(temp))
            texts = read_texts(wheel)
        output = write_texts(args.destination, texts)
    except (OSError, ValueError, UnicodeError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(f"PASS: {wheel}: {len(args.library)} library/libraries matched; notices: {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
