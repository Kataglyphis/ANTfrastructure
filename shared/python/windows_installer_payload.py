#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
"""Extract trusted MSI/MSIX payloads for checks; this does not install or run an app."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import zipfile
from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path, PurePosixPath

from windows_gpu_process import run_process

DEFAULT_FLOOR = 15 * 1024**3 + 512 * 1024**2
DEFAULT_CUSHION = 1024**3
DEFAULT_MAX_EXPANDED = 4 * 1024**3


def require_space(
    directory: Path, size: int, *, floor: int, cushion: int, limit: int
) -> None:
    """Check estimated payload space; this is not an extraction quota."""
    if floor < 0 or cushion < 0 or size <= 0 or size > limit:
        raise ValueError("expanded payload size or disk limits are invalid")
    if shutil.disk_usage(directory).free - size < floor + cushion:
        raise ValueError("insufficient disk space for the estimated installer payload")


def inspect_zip(
    path: Path,
    directory: Path,
    *,
    floor: int = DEFAULT_FLOOR,
    cushion: int = DEFAULT_CUSHION,
    limit: int = DEFAULT_MAX_EXPANDED,
) -> tuple[list[str], int]:
    """Check archive paths, duplicates and expected free space before extraction."""
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if not entries or any(
            item.filename.startswith("/")
            or "\\" in item.filename
            or ":" in item.filename
            or ".." in PurePosixPath(item.filename).parts
            for item in entries
        ):
            raise ValueError("unsafe or empty package ZIP")
        names = [item.filename for item in entries]
        if len({name.casefold() for name in names}) != len(names):
            raise ValueError("duplicate package ZIP entry")
        total = sum(item.file_size for item in entries)
    require_space(directory, total, floor=floor, cushion=cushion, limit=limit)
    return names, total


@contextmanager
def msi_payload(
    package: Path,
    parent: Path,
    size_script: Path,
    *,
    floor: int = DEFAULT_FLOOR,
    cushion: int = DEFAULT_CUSHION,
    limit: int = DEFAULT_MAX_EXPANDED,
) -> Generator[Path, None, None]:
    """Administratively extract a trusted MSI, then remove its temporary payload."""
    powershell = shutil.which("pwsh")
    if not powershell:
        raise ValueError("PowerShell 7 is required on the Windows runner")
    size = int(
        subprocess.check_output(
            [
                powershell,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(size_script),
                str(package),
                "-MaxBytes",
                str(limit),
            ],
            text=True,
            timeout=30,
        ).strip()
    )
    require_space(parent, size, floor=floor, cushion=cushion, limit=limit)
    with tempfile.TemporaryDirectory(
        prefix="gpu-installer-payload-", dir=parent
    ) as temp:
        root = Path(temp) / "msi"
        root.mkdir()
        msiexec = Path(os.environ["SystemRoot"]) / "System32/msiexec.exe"
        if '"' in str(root):
            raise ValueError("invalid quote in MSI extraction path")
        # Windows Installer requires quotes around the value, not the whole property.
        command = subprocess.list2cmdline([str(msiexec), "/a", str(package)])
        command += f' TARGETDIR="{root}" /qn /norestart'
        run_process(
            command,
            timeout=180,
        )
        yield root


@contextmanager
def msix_payload(
    package: Path,
    parent: Path,
    *,
    floor: int = DEFAULT_FLOOR,
    cushion: int = DEFAULT_CUSHION,
    limit: int = DEFAULT_MAX_EXPANDED,
) -> Generator[Path, None, None]:
    """Extract a trusted MSIX archive and remove the temporary payload afterward."""
    inspect_zip(package, parent, floor=floor, cushion=cushion, limit=limit)
    with tempfile.TemporaryDirectory(
        prefix="gpu-installer-payload-", dir=parent
    ) as temp:
        root = Path(temp) / "msix"
        root.mkdir()
        with zipfile.ZipFile(package) as archive:
            archive.extractall(root)
        yield root
