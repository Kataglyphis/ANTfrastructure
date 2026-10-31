#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
"""Stage a GPU artifact only when trusted check receipts match its archive bytes."""

from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import importlib
import os
import stat
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import BinaryIO

sys.path.insert(0, str(Path(__file__).resolve().parent))
receipt = importlib.import_module("gpu_artifact_receipt")

CHECKS = ("clean-host-inference", "gpu-model-inference")
BLOCK = 1024 * 1024


def open_regular(path: Path) -> BinaryIO:
    """Refuse links and non-files before opening an explicitly named input."""
    if receipt.is_link(path) or not path.is_file():
        raise ValueError(f"not a regular input file: {path}")
    stream = path.open("rb")
    if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
        stream.close()
        raise ValueError(f"not a regular input file: {path}")
    return stream


def stream_digest(stream: BinaryIO) -> str:
    """Hash a seekable input from its beginning without loading it all at once."""
    stream.seek(0)
    digest = hashlib.sha256()
    for block in iter(lambda: stream.read(BLOCK), b""):
        digest.update(block)
    return digest.hexdigest()


def archive_entries(
    archive: zipfile.ZipFile, names: list[str], maximum: int, ratio: int
) -> list[zipfile.ZipInfo]:
    """Accept only the exact flat regular files within caller-selected expansion limits."""
    entries = archive.infolist()
    if len(entries) != len(names) or {item.filename for item in entries} != set(names):
        raise ValueError("archive does not contain exactly the expected files")
    total = 0
    for item in entries:
        mode = item.external_attr >> 16
        if (
            item.orig_filename != item.filename
            or item.is_dir()
            or item.external_attr & 0x10
            or stat.S_IFMT(mode) not in (0, stat.S_IFREG)
            or item.flag_bits & 1
        ):
            raise ValueError("archive entries must be unencrypted regular files")
        if item.file_size and (
            not item.compress_size or item.file_size > item.compress_size * ratio
        ):
            raise ValueError("archive compression ratio exceeds the limit")
        total += item.file_size
        if total > maximum:
            raise ValueError("archive uncompressed size exceeds the limit")
    return entries


def checked_receipts(
    paths: list[Path], identity: dict[str, str], names: list[str]
) -> dict[str, str]:
    """Require the distinct checks for the same caller-supplied artifact identity."""
    if paths[0].resolve() == paths[1].resolve():
        raise ValueError("check receipts must be distinct files")
    manifests = []
    for path, check in zip(paths, CHECKS, strict=True):
        if receipt.is_link(path) or not path.is_file():
            raise ValueError("receipt must be a regular file")
        data = receipt.read_receipt(path)
        expected = {**identity, "check": check}
        if data["identity"] != expected:
            raise ValueError(f"{check} receipt does not match the expected identity")
        files = data["files"]
        if set(files) != set(names) or any(
            not isinstance(value, str) or not receipt.SHA256.fullmatch(value)
            for value in files.values()
        ):
            raise ValueError(f"{check} receipt has an invalid file manifest")
        manifests.append(files)
    if manifests[0] != manifests[1]:
        raise ValueError("check receipts describe different package bytes")
    return manifests[0]


def unpack_verified(
    archive: zipfile.ZipFile,
    entries: list[zipfile.ZipInfo],
    target: Path,
    hashes: dict[str, str] | None,
    maximum: int,
) -> None:
    """Copy and rehash ZIP entries into a private temporary directory."""
    total = 0
    for item in entries:
        digest = hashlib.sha256()
        with archive.open(item) as source, (target / item.filename).open("xb") as dest:
            for block in iter(lambda: source.read(BLOCK), b""):
                total += len(block)
                if total > maximum:
                    raise ValueError("expanded archive exceeds the limit")
                digest.update(block)
                dest.write(block)
        if hashes is not None and digest.hexdigest() != hashes[item.filename]:
            raise ValueError(
                f"archive file differs from checked bytes: {item.filename}"
            )


def publish_noreplace(source: Path, target: Path) -> None:
    """Atomically publish a directory without replacing an existing path."""
    if sys.platform == "win32":
        os.rename(source, target)
        return
    if sys.platform != "linux":
        raise OSError(
            "atomic no-replace publication is only supported on Linux and Windows"
        )
    libc = ctypes.CDLL(None, use_errno=True)
    try:
        rename = libc.renameat2
    except AttributeError as exc:
        raise OSError(
            "renameat2 is unavailable; refusing non-atomic publication"
        ) from exc
    rename.argtypes = (
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    )
    rename.restype = ctypes.c_int
    if rename(-100, os.fsencode(source), -100, os.fsencode(target), 1) != 0:
        code = ctypes.get_errno()
        if code in {errno.EINVAL, errno.ENOSYS, errno.EOPNOTSUPP}:
            raise OSError(
                code,
                "filesystem or system rejected atomic no-replace publication; "
                "use a filesystem that supports renameat2 RENAME_NOREPLACE",
                str(target),
            )
        raise OSError(code or errno.EIO, os.strerror(code or errno.EIO), str(target))


def extract_archive(
    archive_path: Path,
    destination: Path,
    digest: str,
    names: list[str],
    maximum: int,
    ratio: int,
    hashes: dict[str, str] | None,
) -> None:
    """Publish exact archive contents only after bounded extraction and digest checks."""
    if maximum < 1 or ratio < 1:
        raise ValueError("expansion limits must be positive")
    destination = destination.absolute()
    parent = destination.parent
    if receipt.is_link(parent) or not parent.is_dir() or os.path.lexists(destination):
        raise ValueError("output must be a new path under a real existing directory")
    with open_regular(archive_path) as source:
        if stream_digest(source) != digest:
            raise ValueError(
                "downloaded archive digest does not match trusted metadata"
            )
        source.seek(0)
        with zipfile.ZipFile(source) as archive:
            entries = archive_entries(archive, names, maximum, ratio)
            with tempfile.TemporaryDirectory(prefix=".gpu-stage-", dir=parent) as temp:
                staged = Path(temp) / "payload"
                staged.mkdir()
                unpack_verified(archive, entries, staged, hashes, maximum)
                if stream_digest(source) != digest:
                    raise ValueError("downloaded archive changed during verification")
                publish_noreplace(staged, destination)


def stage(args: argparse.Namespace) -> None:
    """Bind the staged files to both receipts and the trusted artifact digest."""
    identity = {key: getattr(args, key) for key in receipt.IDENTITY if key != "check"}
    receipt.validate_identity({**identity, "check": CHECKS[0]})
    identity["artifact_digest"] = identity["artifact_digest"].removeprefix("sha256:")
    names = receipt.validate_files(args.file)
    manifests = checked_receipts(
        [Path(args.clean_receipt), Path(args.gpu_receipt)], identity, names
    )
    extract_archive(
        Path(args.archive),
        Path(args.output),
        identity["artifact_digest"],
        names,
        args.max_uncompressed_bytes,
        args.max_compression_ratio,
        manifests,
    )


def main() -> int:
    """Require explicit trusted identity, checks, filenames and expansion limits."""
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("archive", "output", "clean-receipt", "gpu-receipt"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--file", action="append", required=True)
    parser.add_argument("--max-uncompressed-bytes", type=int, required=True)
    parser.add_argument("--max-compression-ratio", type=int, required=True)
    for key in receipt.IDENTITY:
        if key != "check":
            parser.add_argument("--" + key.replace("_", "-"), required=True)
    try:
        stage(parser.parse_args())
    except (OSError, ValueError, TypeError, RuntimeError, zipfile.BadZipFile) as exc:
        print(f"GPU artifact staging: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
