#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Check declared license texts in a package; does not discover its dependency obligations.

Each --require is an archive path glob and a source text, separated by '='.
Supported inputs are directories, ZIP/MSIX/APK/wheels, tar, Debian, MSI, AppImage and Flatpak.
Gzip-compressed entries such as Flutter NOTICES.Z are checked after decompression.
MSI and AppImage require 7-Zip; multiple-cabinet MSI rules use cabinet::file-id,
resolved from the MSI File and Media tables. Cabinets are staged temporarily.
Flatpak requires flatpak and ostree and is imported into a disposable local repository.
"""
from __future__ import annotations

import argparse
import fnmatch
import gzip
import io
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile
import zlib
from collections.abc import Iterator
from pathlib import Path
from typing import IO, Protocol

MAX_LICENSE_BYTES = 16 * 1024 * 1024


class ByteReader(Protocol):
    def read(self, size: int = -1, /) -> bytes: ...


def safe_name(name: str) -> str:
    """Normalize archive separators and reject traversal."""
    name = name.replace("\\", "/")
    while name.startswith("./"):
        name = name[2:]
    if name.startswith("/") or ".." in name.split("/"):
        raise ValueError(f"unsafe archive member: {name}")
    return name


def limited_read(stream: ByteReader) -> bytes:
    """Reject unexpectedly large entries instead of silently truncating them."""
    result = stream.read(MAX_LICENSE_BYTES + 1)
    if len(result) > MAX_LICENSE_BYTES:
        raise ValueError("license entry exceeds the size limit")
    return result


def normalized(content: bytes) -> bytes:
    """Allow platform line endings and unpack Flutter's compressed notice file."""
    if content.startswith(b"\x1f\x8b"):
        with gzip.GzipFile(fileobj=io.BytesIO(content)) as compressed:
            content = limited_read(compressed)
    return content.replace(b"\r\n", b"\n").strip()


def wanted(name: str, rules: list[tuple[str, bytes]]) -> bool:
    """Only open members named by the caller's rules."""
    return any(fnmatch.fnmatchcase(name, pattern) for pattern, _ in rules)


def zip_entries(path: Path, rules: list[tuple[str, bytes]]) -> Iterator[tuple[str, bytes]]:
    with zipfile.ZipFile(path) as archive:
        for entry in archive.infolist():
            name = safe_name(entry.filename)
            mode = entry.external_attr >> 16
            if not entry.is_dir() and not stat.S_ISLNK(mode) and wanted(name, rules):
                with archive.open(entry) as stream:
                    yield name, limited_read(stream)


def tar_entries(stream: IO[bytes], rules: list[tuple[str, bytes]]) -> Iterator[tuple[str, bytes]]:
    with tarfile.open(fileobj=stream, mode="r|*") as archive:
        for entry in archive:
            name = safe_name(entry.name)
            if entry.isfile() and wanted(name, rules):
                member = archive.extractfile(entry)
                if member is None:
                    raise ValueError(f"cannot read archive member: {name}")
                with member:
                    yield name, limited_read(member)


def directory_entries(path: Path, rules: list[tuple[str, bytes]]) -> Iterator[tuple[str, bytes]]:
    for entry in path.rglob("*"):
        name = safe_name(entry.relative_to(path).as_posix())
        if not entry.is_symlink() and entry.is_file() and wanted(name, rules):
            with entry.open("rb") as stream:
                yield name, limited_read(stream)


def deb_entries(path: Path, rules: list[tuple[str, bytes]]) -> list[tuple[str, bytes]]:
    """Read dpkg's payload stream and require a successful decompression exit."""
    with subprocess.Popen(["dpkg-deb", "--fsys-tarfile", str(path)], stdout=subprocess.PIPE) as proc:
        assert proc.stdout is not None
        try:
            result = list(tar_entries(proc.stdout, rules))
        finally:
            proc.stdout.close()
        if proc.wait() != 0:
            raise ValueError("dpkg-deb could not read the package")
    return result


def sevenzip_member_records(path: Path, *, compound: bool = False) -> list[tuple[str, int | None]]:
    """Read archive metadata before selecting exact members."""
    listing = subprocess.run(
        ["7z", "l", "-slt", *(["-tCompound"] if compound else []), "--", str(path)],
        check=True, capture_output=True, text=True
    ).stdout
    _, separator, members = listing.partition("----------")
    if not separator:
        raise ValueError("7-Zip did not return an archive member list")
    result: list[tuple[str, int | None]] = []
    name: str | None = None
    size: int | None = None
    for line in members.splitlines():
        if line.startswith("Path = "):
            if name is not None:
                result.append((name, size))
            name, size = line.removeprefix("Path = "), None
        elif name is not None and line.startswith("Size = "):
            value = line.removeprefix("Size = ")
            size = int(value) if value.isdecimal() else None
    if name is not None:
        result.append((name, size))
    return result


def sevenzip_member_names(path: Path, *, compound: bool = False) -> list[str]:
    return [safe_name(name) for name, _ in sevenzip_member_records(path, compound=compound)]


def sevenzip_selected_entries(path: Path, names: list[str], rules: list[tuple[str, bytes]]) -> Iterator[tuple[str, bytes]]:
    """Read matching cabinet or SquashFS members without extracting their paths."""
    for name in names:
        if wanted(name, rules):
            with subprocess.Popen(
                ["7z", "e", "-so", "-spd", "--", str(path), name], stdout=subprocess.PIPE
            ) as proc:
                assert proc.stdout is not None
                try:
                    content = limited_read(proc.stdout)
                finally:
                    proc.stdout.close()
                if proc.wait() != 0:
                    raise ValueError(f"7-Zip could not read archive member: {name}")
            yield name, content


def msi_cabinet_checks(names: list[str], rules: list[tuple[str, bytes]]) -> dict[str, list[tuple[str, str, bytes]]]:
    """Require the caller's Media-table mapping when an MSI has several cabinets."""
    cabinets = [name for name in names if name.lower().endswith(".cab")]
    if not cabinets:
        raise ValueError("MSI has no embedded cabinet")
    if len({name.casefold() for name in cabinets}) != len(cabinets) or any("/" in name or "::" in name for name in cabinets):
        raise ValueError("ambiguous or unsafe embedded MSI cabinet names")
    selected: dict[str, list[tuple[str, str, bytes]]] = {}
    for pattern, expected in rules:
        if "::" in pattern:
            cabinet, member = pattern.split("::", 1)
            if cabinet not in cabinets or not member or "::" in member:
                raise ValueError(f"invalid or missing MSI cabinet mapping: {pattern}")
        else:
            if len(cabinets) != 1:
                raise ValueError("MSI with multiple cabinets requires a Media-table cabinet mapping")
            cabinet, member = cabinets[0], pattern
        selected.setdefault(cabinet, []).append((pattern, member, expected))
    return selected


def msi_selected_names(staged: Path, checks: list[tuple[str, str, bytes]]) -> list[str]:
    """Reject unsafe or ambiguous matching identifiers before extracting them."""
    inner_rules = [(member, expected) for _, member, expected in checks]
    folded_rules = [(member.casefold(), expected) for member, expected in inner_rules]
    names = []
    seen: set[str] = set()
    for raw, size in sevenzip_member_records(staged):
        name = safe_name(raw)
        if not wanted(name.casefold(), folded_rules):
            continue
        if name != raw or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]*", name):
            raise ValueError(f"unsafe MSI cabinet member: {raw}")
        if name.casefold() in seen:
            raise ValueError(f"duplicate MSI cabinet member: {name}")
        if size is None or size > MAX_LICENSE_BYTES:
            raise ValueError(f"invalid or oversized MSI cabinet member: {name}")
        seen.add(name.casefold())
        names.append(name)
    return names


def msi_cabinet_entries(path: Path, cabinet: str, staged: Path,
                        checks: list[tuple[str, str, bytes]]) -> Iterator[tuple[str, bytes]]:
    """Stage the CAB stream once, then extract the selected files together."""
    with staged.open("wb") as stream:
        subprocess.run(["7z", "e", "-tCompound", "-so", "-spd", "--", str(path), cabinet], stdout=stream, check=True)
    names = msi_selected_names(staged, checks)
    if not names:
        return
    with tempfile.TemporaryDirectory(prefix="package-msi-members-") as temporary:
        subprocess.run(["7z", "x", "-y", "-spd", f"-o{temporary}", "--", str(staged), *names],
                       check=True, capture_output=True)
        if {entry.name for entry in Path(temporary).iterdir()} != set(names):
            raise ValueError("MSI cabinet extraction returned unexpected members")
        for name in names:
            extracted = Path(temporary) / name
            if extracted.is_symlink() or not extracted.is_file():
                raise ValueError(f"MSI cabinet member is not a regular file: {name}")
            with extracted.open("rb") as stream:
                content = limited_read(stream)
            for pattern, member, _ in checks:
                if fnmatch.fnmatchcase(name, member):
                    yield f"{cabinet}::{name}" if "::" in pattern else name, content


def msi_entries(path: Path, rules: list[tuple[str, bytes]]) -> Iterator[tuple[str, bytes]]:
    """Inspect only embedded cabinets selected by the MSI Media table."""
    selected = msi_cabinet_checks(sevenzip_member_names(path, compound=True), rules)
    with tempfile.TemporaryDirectory(prefix="package-msi-cabinets-") as temporary:
        for index, (cabinet, checks) in enumerate(selected.items()):
            yield from msi_cabinet_entries(path, cabinet, Path(temporary) / f"{index}.cab", checks)


def flatpak_entries(path: Path, rules: list[tuple[str, bytes]]) -> Iterator[tuple[str, bytes]]:
    """Import into a private repository and inspect one checkout without installing it."""
    with tempfile.TemporaryDirectory(prefix="package-licenses-") as temporary:
        temp = Path(temporary)
        repo = temp / "repo"
        checkout = temp / "checkout"
        subprocess.run(["ostree", "init", f"--repo={repo}", "--mode=archive"], check=True, capture_output=True)
        subprocess.run(["flatpak", "build-import-bundle", str(repo), str(path.resolve())], check=True, capture_output=True)
        refs = subprocess.run(["ostree", "refs", f"--repo={repo}"], check=True, capture_output=True, text=True).stdout.splitlines()
        if len(refs) != 1 or not refs[0].startswith("app/"):
            raise ValueError(f"expected one Flatpak application ref, found {refs!r}")
        subprocess.run(["ostree", "checkout", f"--repo={repo}", "--user-mode", refs[0], str(checkout)], check=True, capture_output=True)
        yield from directory_entries(checkout, rules)


def package_entries(path: Path, rules: list[tuple[str, bytes]]) -> Iterator[tuple[str, bytes]]:
    if path.is_dir():
        yield from directory_entries(path, rules)
    elif path.suffix.lower() == ".deb":
        yield from deb_entries(path, rules)
    elif zipfile.is_zipfile(path):
        yield from zip_entries(path, rules)
    elif path.suffix.lower() == ".flatpak":
        yield from flatpak_entries(path, rules)
    elif path.suffix.lower() == ".msi":
        yield from msi_entries(path, rules)
    elif path.suffix.lower() == ".appimage":
        yield from sevenzip_selected_entries(path, sevenzip_member_names(path), rules)
    else:
        with path.open("rb") as stream:
            yield from tar_entries(stream, rules)


def load_rules(items: list[str]) -> list[tuple[str, bytes]]:
    rules = []
    for item in items:
        pattern, separator, source = item.partition("=")
        if not separator or not pattern or not source:
            raise ValueError(f"invalid rule: {item!r}; expected GLOB=SOURCE")
        with Path(source).open("rb") as stream:
            expected = normalized(limited_read(stream))
        if not expected:
            raise ValueError(f"empty expected license: {source}")
        rules.append((safe_name(pattern), expected))
    return rules


def check_package(path: Path, rules: list[tuple[str, bytes]]) -> list[str]:
    """Every rule needs a matching regular file containing the complete supplied text."""
    found = [False] * len(rules)
    for name, content in package_entries(path, rules):
        content = normalized(content)
        for index, (pattern, expected) in enumerate(rules):
            if fnmatch.fnmatchcase(name, pattern) and expected in content:
                found[index] = True
    return [pattern for (pattern, _), matched in zip(rules, found, strict=True) if not matched]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--require", action="append", required=True, metavar="GLOB=SOURCE")
    args = parser.parse_args()
    try:
        missing = check_package(args.package, load_rules(args.require))
    except (OSError, ValueError, tarfile.TarError, zipfile.BadZipFile, EOFError, subprocess.CalledProcessError, zlib.error) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    if missing:
        for pattern in missing:
            print(f"FAIL: missing or incorrect license text: {pattern}", file=sys.stderr)
        return 1
    print(f"PASS: {args.package}: {len(args.require)} declared license text(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
