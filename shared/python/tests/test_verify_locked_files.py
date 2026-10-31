#!/usr/bin/env python3
"""Exercise packaged data-lock verification without downloads or a GPU."""

from __future__ import annotations

import hashlib
import runpy
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[3]
VERIFY = ROOT / "shared/python/verify_locked_files.py"
FETCHER = ROOT / "linux/scripts/lib/fetch-data-lock.py"
NAMES = ("model.onnx", "model.LICENSE", "model.NOTICE")


class LockedFilesTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "package"
        self.files = self.root / "resources/models"
        self.files.mkdir(parents=True)
        rows = []
        for name in NAMES:
            contents = f"fixture {name}\n".encode()
            (self.files / name).write_bytes(contents)
            rows.append(
                f"{hashlib.sha256(contents).hexdigest()}  {name}  https://example.invalid/{name}\n"
            )
        self.lock = self.base / "models.lock"
        self.lock.write_text("".join(rows), encoding="utf-8")

    def run_check(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                "-I",
                str(VERIFY),
                "--root",
                str(self.root),
                "--directory",
                str(self.files),
                "--lock",
                str(self.lock),
                "--fetcher",
                str(FETCHER),
                *extra,
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    def names(self) -> tuple[str, ...]:
        return tuple(value for name in NAMES for value in ("--file", name))

    def test_exact_locked_files_pass(self) -> None:
        result = self.run_check(*self.names())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_and_changed_files_fail(self) -> None:
        for name in NAMES:
            with self.subTest(name=name):
                path = self.files / name
                original = path.read_bytes()
                path.write_bytes(b"changed")
                self.assertNotEqual(self.run_check(*self.names()).returncode, 0)
                path.unlink()
                self.assertNotEqual(self.run_check(*self.names()).returncode, 0)
                path.write_bytes(original)

    def test_directory_outside_package_root_fails(self) -> None:
        outside = self.base / "outside"
        self.files.rename(outside)
        self.files = outside
        self.assertNotEqual(self.run_check(*self.names()).returncode, 0)

    def test_missing_or_duplicate_lock_entries_fail(self) -> None:
        rows = self.lock.read_text(encoding="utf-8").splitlines()
        self.lock.write_text("\n".join(rows[:-1]) + "\n", encoding="utf-8")
        self.assertNotEqual(self.run_check(*self.names()).returncode, 0)
        self.lock.write_text("\n".join(rows + rows[:1]) + "\n", encoding="utf-8")
        self.assertNotEqual(self.run_check(*self.names()).returncode, 0)

    def test_duplicate_or_escaping_names_fail(self) -> None:
        for names in (
            (*self.names(), "--file", NAMES[0]),
            ("--file", "model.onnx", "--file", "MODEL.ONNX"),
            ("--file", "../outside"),
            ("--file", "dir\\file"),
        ):
            with self.subTest(names=names):
                self.assertNotEqual(self.run_check(*names).returncode, 0)

    def test_windows_reparse_point_is_linked(self) -> None:
        api = runpy.run_path(str(VERIFY))
        path = Mock(spec=Path)
        path.is_symlink.return_value = False
        path.lstat.return_value = SimpleNamespace(st_file_attributes=0x400)
        self.assertTrue(api["is_link"](path))
        path.lstat.return_value = SimpleNamespace(st_file_attributes=0)
        self.assertFalse(api["is_link"](path))

    def test_linked_file_and_directory_fail(self) -> None:
        target = self.base / "outside"
        target.mkdir()
        link = self.files / NAMES[0]
        link.unlink()
        try:
            link.symlink_to(target / NAMES[0])
        except OSError as error:
            self.skipTest(f"symlink creation unavailable: {error}")
        self.assertNotEqual(self.run_check(*self.names()).returncode, 0)
        link.unlink()
        link.write_bytes(b"fixture model.onnx\n")
        self.assertEqual(self.run_check(*self.names()).returncode, 0)
        self.files.rename(self.root / "original-models")
        self.files.symlink_to(self.root / "original-models", target_is_directory=True)
        self.assertNotEqual(self.run_check(*self.names()).returncode, 0)


if __name__ == "__main__":
    unittest.main()
