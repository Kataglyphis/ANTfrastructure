#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Stage ONNX Runtime wheel notices after byte-matching the packaged native ELFs.

Each supplied library must match its uniquely named wheel component, either as-is
or after stripping the wheel entry with the selected target-architecture tool.
With --require-unstripped, only exact wheel bytes are accepted and no copy is made.
With --restore-unstripped, validated in-bundle copies become their matching original
wheel bytes. Publication is per file; failure leaves the bundle unaccepted.
The check does not enumerate other native libraries or their legal obligations.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
from contextlib import nullcontext
from pathlib import Path

from ort_census_probe import elf_target, file_sha

MAX_LIBRARY_BYTES = 1024 * 1024 * 1024
MAX_TEXT_BYTES = 16 * 1024 * 1024
CHUNK_BYTES = 1024 * 1024
TEXTS = ("LICENSE", "ThirdPartyNotices.txt")
ORT_LIBRARY = re.compile(r"^(libonnxruntime(?:_providers_[a-zA-Z0-9_]+)?\.so)(?:\.\d+)*$")
NativeOriginal = tuple[Path, Path, str, str, int]


def checked_entry(archive: zipfile.ZipFile, name: str, limit: int) -> zipfile.ZipInfo | None:
    """Reject duplicate, linked, empty or excessively large expected entries."""
    entries = [entry for entry in archive.infolist() if entry.filename == name]
    if not entries:
        return None
    if len(entries) != 1:
        raise ValueError(f"duplicate wheel entry: {name}")
    entry = entries[0]
    if entry.is_dir() or stat.S_ISLNK(entry.external_attr >> 16) or not 0 < entry.file_size <= limit:
        raise ValueError(f"invalid wheel entry: {name}")
    return entry


def entry_bytes(archive: zipfile.ZipFile, name: str, limit: int) -> bytes | None:
    """Read a bounded text entry after validating its archive metadata."""
    entry = checked_entry(archive, name, limit)
    if entry is None:
        return None
    with archive.open(entry) as stream:
        content = stream.read(limit + 1)
    if len(content) != entry.file_size or len(content) > limit:
        raise ValueError(f"invalid wheel entry size: {name}")
    return content


def wheel_component(archive: zipfile.ZipFile, library: Path) -> tuple[zipfile.ZipInfo, str] | None:
    """Find the library's unique component in a wheel, or return None."""
    component = ORT_LIBRARY.fullmatch(library.name)
    target = ORT_LIBRARY.fullmatch(library.resolve(strict=True).name)
    if component is None or target is None or component.group(1) != target.group(1):
        raise ValueError(f"ONNX Runtime library name does not match its target: {library}")
    prefix = "onnxruntime/capi/"
    entries = [entry.filename for entry in archive.infolist() if entry.filename.startswith(prefix)
               and (match := ORT_LIBRARY.fullmatch(entry.filename[len(prefix):]))
               and match.group(1) == component.group(1)]
    if not entries:
        return None
    if len(entries) != 1:
        raise ValueError(f"ambiguous wheel component: {component.group(1)}")
    entry = checked_entry(archive, entries[0], MAX_LIBRARY_BYTES)
    if entry is None:
        raise ValueError(f"missing wheel component: {entries[0]}")
    return entry, component.group(1)


def copy_wheel_component(archive: zipfile.ZipFile, entry: zipfile.ZipInfo,
                         native_target: tuple[int, int, int], copied: Path | None) -> str | None:
    """Hash in bounded chunks, writing a scratch copy only if stripping may be needed."""
    digest = hashlib.sha256()
    with archive.open(entry) as stream:
        header = stream.read(20)
        if elf_target(header) != native_target:
            return None
        size = len(header)
        digest.update(header)
        with copied.open("wb") if copied is not None else nullcontext() as target:
            if target is not None:
                target.write(header)
            while chunk := stream.read(CHUNK_BYTES):
                size += len(chunk)
                if size > entry.file_size or size > MAX_LIBRARY_BYTES:
                    raise ValueError(f"invalid wheel entry size: {entry.filename}")
                digest.update(chunk)
                if target is not None:
                    target.write(chunk)
    if size != entry.file_size:
        raise ValueError(f"invalid wheel entry size: {entry.filename}")
    return digest.hexdigest()


def wheel_has_library(archive: zipfile.ZipFile, library: Path, strip: str, scratch: Path,
                      require_unstripped: bool = False) -> bool:
    """Require byte identity, not just a release version or a source marker."""
    component = wheel_component(archive, library)
    if component is None:
        return False
    entry, name = component
    with library.open("rb") as stream:
        native_target = elf_target(stream.read(20))
    expected = file_sha(str(library))
    copied = None if require_unstripped else scratch / name
    digest = copy_wheel_component(archive, entry, native_target, copied)
    if digest is None:
        return False
    if digest == expected:
        return True
    if copied is None:
        return False
    subprocess.run([strip, "--strip-all", "--", str(copied)], check=True, capture_output=True)
    return file_sha(str(copied)) == expected


def selected_wheel(directory: Path, libraries: list[Path], strip: str, scratch: Path,
                   require_unstripped: bool = False) -> Path:
    """One wheel must independently match every requested delivered library."""
    if not directory.is_dir():
        raise ValueError(f"wheel directory is missing: {directory}")
    matches = []
    for wheel in sorted(directory.glob("onnxruntime*.whl")):
        if wheel.name.startswith("onnxruntime_genai-"):
            continue
        with zipfile.ZipFile(wheel) as archive:
            if all(wheel_has_library(archive, library, strip, scratch, require_unstripped) for library in libraries):
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


def require_unchanged_library(library: Path, expected: str) -> None:
    """A late source replacement cannot be overwritten by an earlier wheel proof."""
    if library.is_symlink() or not library.is_file() or file_sha(str(library)) != expected:
        raise ValueError(f"native library changed before original-byte staging: {library}")


def original_library_destination(library: Path, destination: Path) -> Path:
    """Original-byte restoration may replace only regular files inside its bundle."""
    if library.is_symlink():
        raise ValueError(f"linked native library: {library}")
    root = destination.resolve(strict=True)
    target = library.resolve(strict=True)
    if not root.is_dir() or not target.is_relative_to(root):
        raise ValueError(f"native library escapes bundle: {library}")
    return target


def original_library_plan(wheel: Path, libraries: list[Path], destination: Path,
                          strip: str, scratch: Path, inputs: dict[Path, str]) -> list[NativeOriginal]:
    """Freeze every validated original before writing any destination files."""
    originals = scratch / "originals"
    originals.mkdir()
    plan: list[NativeOriginal] = []
    seen: set[Path] = set()
    with zipfile.ZipFile(wheel) as archive:
        for library in libraries:
            target = original_library_destination(library, destination)
            if target in seen:
                raise ValueError(f"duplicate native destination: {target}")
            seen.add(target)
            require_unchanged_library(target, inputs[library])
            if not wheel_has_library(archive, target, strip, scratch):
                raise ValueError(f"native library no longer matches selected wheel: {library}")
            component = wheel_component(archive, target)
            if component is None:
                raise ValueError(f"missing original wheel component: {library}")
            original = originals / target.name
            with target.open("rb") as stream:
                digest = copy_wheel_component(archive, component[0], elf_target(stream.read(20)), original)
            if digest is None:
                raise ValueError(f"original wheel target differs: {library}")
            plan.append((target, original, inputs[library], digest, stat.S_IMODE(target.stat().st_mode)))
    return plan


def publish_original_library(plan: NativeOriginal) -> None:
    """Validate a complete same-directory copy before replacing one checked file."""
    library, original, before_sha, original_sha, mode = plan
    require_unchanged_library(library, before_sha)
    with tempfile.NamedTemporaryFile(prefix=".ort-original-", dir=library.parent, delete=False) as stream:
        pending = Path(stream.name)
        try:
            with original.open("rb") as source:
                shutil.copyfileobj(source, stream, CHUNK_BYTES)
            stream.flush()
            os.fchmod(stream.fileno(), mode)
            if file_sha(str(pending)) != original_sha:
                raise ValueError(f"original wheel copy is incomplete: {library}")
            require_unchanged_library(library, before_sha)
            os.replace(pending, library)
        finally:
            pending.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wheel-dir", type=Path, required=True)
    parser.add_argument("--library", type=Path, action="append", required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--strip", required=True, help="target-compatible strip executable")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--require-unstripped", action="store_true", help="require byte-identical wheel libraries without a strip fallback")
    mode.add_argument("--restore-unstripped", action="store_true", help="replace validated in-bundle libraries with their matching original wheel bytes")
    args = parser.parse_args()
    try:
        if not args.require_unstripped and not shutil.which(args.strip):
            raise ValueError(f"strip executable not found: {args.strip}")
        for library in args.library:
            if not library.is_file() or not ORT_LIBRARY.fullmatch(library.resolve().name):
                raise ValueError(f"not a native ONNX Runtime library: {library}")
        inputs = {library: file_sha(str(library)) for library in args.library} if args.restore_unstripped else {}
        with tempfile.TemporaryDirectory(prefix="ort-wheel-license-") as temp:
            wheel = selected_wheel(args.wheel_dir, args.library, args.strip, Path(temp), args.require_unstripped)
            texts = read_texts(wheel)
            originals = original_library_plan(wheel, args.library, args.destination, args.strip, Path(temp), inputs) if args.restore_unstripped else []
            output = write_texts(args.destination, texts)
            for original in originals:
                publish_original_library(original)
    except (OSError, ValueError, UnicodeError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    if args.restore_unstripped:
        print(f"PASS: restored {len(originals)} original wheel library/libraries")
    print(f"PASS: {wheel}: {len(args.library)} library/libraries matched; notices: {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
