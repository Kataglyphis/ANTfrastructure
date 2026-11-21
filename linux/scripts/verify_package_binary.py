#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Compare exact binary members in directories, TAR, DEB, ZIP/MSIX/wheels or MSI to source files.

Rules are exact MEMBER=SOURCE pairs, not globs. MSI members use the embedded
cabinet and File-table identifier returned by Get-MsiCabinetPattern. The check
proves regular-file byte equality, not source provenance, executable mode, loader
behavior or the integrity of unselected members. TAR permits one conventional
leading './' but rejects duplicate or ambiguous selected paths.
"""
# PACKAGE_BINARY_WHEEL_API=1

# PACKAGE_BINARY_LINUX_API=1

from __future__ import annotations

import argparse
import hashlib
import re
import runpy
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path
from typing import IO

_shared = runpy.run_path(str(Path(__file__).with_name("verify_package_license.py")))
safe_name = _shared["safe_name"]
sevenzip_member_names = _shared["sevenzip_member_names"]
msi_cabinet_checks = _shared["msi_cabinet_checks"]
checked_deb_payload = _shared["checked_deb_payload"]


def digest(stream: IO[bytes]) -> tuple[str, int]:
    """Hash a stream without retaining its contents in memory."""
    value = hashlib.sha256()
    size = 0
    while chunk := stream.read(1024 * 1024):
        value.update(chunk)
        size += len(chunk)
    return value.hexdigest(), size


def exact_name(name: str) -> str:
    """Reject wildcards and ambiguous paths before a 7-Zip or ZIP lookup."""
    result = safe_name(name)
    if (
        not result
        or result != name
        or any(c in result for c in "*?[]:=")
        or any(part in ("", ".", "..") for part in result.split("/"))
    ):
        raise ValueError(f"not an exact package member: {name!r}")
    return result


def load_rules(items: list[str], *, msi: bool) -> dict[str, tuple[str, int]]:
    rules: dict[str, tuple[str, int]] = {}
    for item in items:
        name, separator, source = item.partition("=")
        if not separator or not name or not source:
            raise ValueError(f"invalid rule: {item!r}; expected MEMBER=SOURCE")
        if msi:
            cabinet, sep, member = name.partition("::")
            if not sep or "::" in member:
                raise ValueError("MSI members require cabinet.cab::file-id")
            if (
                "/" in cabinet
                or "\\" in cabinet
                or not cabinet.lower().endswith(".cab")
            ):
                raise ValueError("MSI cabinet must be an embedded cabinet basename")
            if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]*", member):
                raise ValueError("MSI member must be a File-table identifier")
            name = f"{exact_name(cabinet)}::{exact_name(member)}"
        else:
            name = exact_name(name)
        if name.casefold() in {existing.casefold() for existing in rules}:
            raise ValueError(f"duplicate package member rule: {name}")
        with Path(source).open("rb") as stream:
            expected = digest(stream)
        if not expected[1]:
            raise ValueError(f"empty binary source: {source}")
        rules[name] = expected
    return rules


def selected_name(raw: str, names: dict[str, str]) -> str | None:
    canonical = "/".join(part for part in safe_name(raw).split("/") if part not in ("", "."))
    return names.get(canonical.casefold())


def require_member_count(name: str, count: int) -> None:
    if count != 1:
        raise ValueError(f"package member {name!r} matched {count} entries; expected one")


def require_regular_member(name: str, actual_name: str, regular: bool) -> None:
    if actual_name != name:
        raise ValueError(f"package member path differs: {name}")
    if not regular:
        raise ValueError(f"package member is not a regular file: {name}")


def require_binary(actual: tuple[str, int], expected: tuple[str, int], name: str) -> None:
    if actual != expected:
        raise ValueError(f"package binary differs from source: {name}")


def check_zip(path: Path, rules: dict[str, tuple[str, int]]) -> None:
    with zipfile.ZipFile(path) as archive:
        entries: dict[str, list[zipfile.ZipInfo]] = {name: [] for name in rules}
        names = {name.casefold(): name for name in rules}
        for entry in archive.infolist():
            name = selected_name(entry.filename, names)
            if name is not None:
                entries[name].append(entry)
        for name, found in entries.items():
            require_member_count(name, len(found))
            entry = found[0]
            mode_type = stat.S_IFMT(entry.external_attr >> 16)
            require_regular_member(name, entry.filename, not entry.is_dir() and mode_type in (0, stat.S_IFREG))
            with archive.open(entry) as stream:
                require_binary(digest(stream), rules[name], name)


def check_directory(path: Path, rules: dict[str, tuple[str, int]]) -> None:
    if path.is_symlink():
        raise ValueError("extracted package root must not be a symlink")
    entries: dict[str, list[Path]] = {name: [] for name in rules}
    names = {name.casefold(): name for name in rules}
    for entry in path.rglob("*"):
        name = selected_name(entry.relative_to(path).as_posix(), names)
        if name is not None:
            entries[name].append(entry)
    for name, found in entries.items():
        require_member_count(name, len(found))
        entry = found[0]
        require_regular_member(name, entry.relative_to(path).as_posix(), stat.S_ISREG(entry.lstat().st_mode))
        with entry.open("rb") as stream:
            require_binary(digest(stream), rules[name], name)


def check_tar(stream: IO[bytes], rules: dict[str, tuple[str, int]]) -> None:
    counts = dict.fromkeys(rules, 0)
    names = {name.casefold(): name for name in rules}
    with tarfile.open(fileobj=stream, mode="r|*") as archive:
        for entry in archive:
            name = selected_name(entry.name, names)
            if name is None:
                continue
            counts[name] += 1
            require_regular_member(name, entry.name.removeprefix("./"), entry.isfile())
            member = archive.extractfile(entry)
            if member is None:
                raise ValueError(f"cannot read package member: {name}")
            with member:
                require_binary(digest(member), rules[name], name)
    for name, count in counts.items():
        require_member_count(name, count)


def extract_cabinet(path: Path, name: str, output: Path) -> None:
    with output.open("wb") as stream:
        subprocess.run(
            ["7z", "e", "-tCompound", "-so", "-spd", "--", str(path), name],
            stdout=stream,
            stderr=subprocess.PIPE,
            check=True,
        )


def hash_cabinet_member(cabinet: Path, member: str) -> tuple[str, int]:
    """Stream one 7-Zip extraction and preserve its exit status."""
    with tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(
            ["7z", "e", "-so", "-spd", "--", str(cabinet), member],
            stdout=subprocess.PIPE,
            stderr=errors,
        )
        assert process.stdout is not None
        try:
            actual = digest(process.stdout)
        except BaseException:
            process.kill()
            process.wait()
            raise
        finally:
            process.stdout.close()
        status = process.wait()
        if status:
            errors.seek(0)
            message = errors.read(4096).decode("utf-8", errors="replace").strip()
            raise ValueError(f"7-Zip failed extracting {member}: {status}: {message}")
        return actual


def check_msi(path: Path, rules: dict[str, tuple[str, int]]) -> None:
    selected = msi_cabinet_checks(
        sevenzip_member_names(path, compound=True), [(name, b"") for name in rules]
    )
    with tempfile.TemporaryDirectory(prefix="package-binaries-") as temporary:
        for index, (cabinet, members) in enumerate(selected.items()):
            cab = Path(temporary) / f"{index}.cab"
            extract_cabinet(path, cabinet, cab)
            names = sevenzip_member_names(cab)
            for rule, member, _ in members:
                count = sum(name.casefold() == member.casefold() for name in names)
                if count != 1:
                    raise ValueError(
                        f"cabinet member {rule!r} matched {count} entries; expected one"
                    )
                if member not in names:
                    raise ValueError(f"cabinet member case differs: {rule}")
                require_binary(hash_cabinet_member(cab, member), rules[rule], rule)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument(
        "--require", action="append", required=True, metavar="MEMBER=SOURCE"
    )
    args = parser.parse_args()
    try:
        msi = args.package.suffix.lower() == ".msi"
        rules = load_rules(args.require, msi=msi)
        if args.package.is_dir():
            check_directory(args.package, rules)
        elif msi:
            check_msi(args.package, rules)
        elif args.package.suffix.lower() in (".zip", ".msix", ".whl"):
            check_zip(args.package, rules)
        elif args.package.suffix.lower() == ".deb":
            checked_deb_payload(args.package, lambda stream: check_tar(stream, rules))
        elif tarfile.is_tarfile(args.package):
            with args.package.open("rb") as stream:
                check_tar(stream, rules)
        else:
            raise ValueError("package must be a directory, TAR, DEB, ZIP, MSIX, wheel or MSI")
    except (
        OSError,
        ValueError,
        zipfile.BadZipFile,
        tarfile.TarError,
        EOFError,
        subprocess.CalledProcessError,
    ) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    print(f"PASS: {args.package}: {len(rules)} exact binary member(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
