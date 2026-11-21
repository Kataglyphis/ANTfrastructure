"""Build archive fixtures with explicit member names and bytes."""

import io
import tarfile
import zipfile
from collections.abc import Sequence
from pathlib import Path
from typing import Literal


def write_zip(path: Path, entries: list[tuple[str, bytes]], compression: int = zipfile.ZIP_STORED) -> None:
    with zipfile.ZipFile(path, "w", compression=compression) as archive:
        for name, data in entries:
            archive.writestr(name, data)


def write_symlink_zip(path: Path, name: str, data: bytes) -> None:
    link = zipfile.ZipInfo(name)
    link.create_system = 3
    link.external_attr = 0o120777 << 16
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(link, data)


def write_tar(path: Path, entries: Sequence[tuple[str, bytes] | tarfile.TarInfo], mode: Literal["w", "w:gz"] = "w:gz") -> None:
    with tarfile.open(path, mode) as archive:
        for entry in entries:
            if isinstance(entry, tarfile.TarInfo):
                archive.addfile(entry)
            else:
                name, data = entry
                info = tarfile.TarInfo(name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
