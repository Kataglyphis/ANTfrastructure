"""Build archive fixtures with explicit member names and bytes."""

import zipfile
from pathlib import Path


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
