#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Verify compression, RECORD quoting and failure atomicity on actual wheel archives."""
import csv
import io
from pathlib import Path
import runpy
import tempfile
import unittest
import zipfile

HELPER = Path(__file__).resolve().parents[3] / "shared/python/kataglyphis_wheel.py"
rewrite_wheel = runpy.run_path(str(HELPER))["rewrite_wheel"]


class WheelRewriteTests(unittest.TestCase):
    def test_compression_record_quoting_and_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.whl"
            data = b"extension" * 10000
            with zipfile.ZipFile(path, "w") as archive:
                item = zipfile.ZipInfo("module,one.so", (2026, 1, 2, 3, 4, 6))
                item.external_attr = 0o755 << 16
                archive.writestr(item, data)
                archive.writestr("module.py", "source")
                archive.writestr("pkg.dist-info/METADATA", "Name: pkg\n")
                archive.writestr("pkg.dist-info/RECORD", "old")
                archive.writestr("pkg.dist-info/RECORD.jws", "signature")
            rewrite_wheel(path, (".py",))
            with zipfile.ZipFile(path) as archive:
                info = archive.getinfo("module,one.so")
                self.assertEqual(info.compress_type, zipfile.ZIP_DEFLATED)
                self.assertLess(info.compress_size, len(data) // 10)
                self.assertEqual(info.date_time, item.date_time)
                self.assertEqual(info.external_attr, item.external_attr)
                self.assertNotIn("module.py", archive.namelist())
                self.assertNotIn("pkg.dist-info/RECORD.jws", archive.namelist())
                rows = list(csv.reader(io.StringIO(archive.read("pkg.dist-info/RECORD").decode())))
                self.assertEqual(rows[0][0], "module,one.so")
                self.assertEqual(rows[0][2], str(len(data)))
                self.assertEqual(rows[-1], ["pkg.dist-info/RECORD", "", ""])

    def test_invalid_wheel_preserves_original_and_leaves_no_temporary(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.whl"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("module.so", b"code")
            original = path.read_bytes()
            with self.assertRaisesRegex(ValueError, "exactly one"):
                rewrite_wheel(path, (".py",))
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(list(Path(directory).iterdir()), [path])


if __name__ == "__main__":
    unittest.main()
