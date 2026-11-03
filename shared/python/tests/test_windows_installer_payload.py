#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
"""Exercise trusted installer extraction; no app installation or GPU is tested."""

from __future__ import annotations

import importlib
import os
import re
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
payload = importlib.import_module("windows_installer_payload")


class WindowsInstallerPayloadTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.msix = self.root / "fixture.msix"
        with zipfile.ZipFile(self.msix, "w") as archive:
            archive.writestr("bin/demo.exe", b"synthetic")

    def test_msix_payload_and_cleanup_after_success_and_failure(self) -> None:
        for raises in (False, True):
            with self.subTest(raises=raises):
                try:
                    with payload.msix_payload(
                        self.msix, self.root, floor=0, cushion=0
                    ) as extracted:
                        self.assertEqual(
                            (extracted / "bin/demo.exe").read_bytes(), b"synthetic"
                        )
                        if raises:
                            raise RuntimeError("fixture failure")
                except RuntimeError:
                    self.assertTrue(raises)
                self.assertFalse(extracted.exists())

    def test_rejects_unsafe_duplicate_and_unavailable_space(self) -> None:
        for index, names in enumerate((("../escape",), ("bin/A", "bin/a"), ("x:y",))):
            path = self.root / f"bad-{index}.msix"
            with zipfile.ZipFile(path, "w") as archive:
                for name in names:
                    archive.writestr(name, b"fixture")
            with self.assertRaises(ValueError):
                payload.inspect_zip(path, self.root, floor=0, cushion=0)
        with (
            mock.patch.object(
                payload.shutil, "disk_usage", return_value=mock.Mock(free=9)
            ),
            self.assertRaises(ValueError),
        ):
            payload.inspect_zip(self.msix, self.root, floor=5, cushion=1)

    def test_msi_uses_size_guard_and_cleans_on_callback_failure(self) -> None:
        seen = []

        parent = self.root / "directory with spaces"
        parent.mkdir()

        def fake_extract(command: str, *, timeout: int) -> None:
            self.assertEqual(timeout, 180)
            match = re.search(r' TARGETDIR="([^"]+)" /qn /norestart$', command)
            if match is None:
                self.fail(command)
            target = Path(match.group(1))
            self.assertEqual(target.parent.parent, parent)
            (target / "demo.exe").write_bytes(b"synthetic")
            seen.append(target)

        with (
            mock.patch.object(payload.shutil, "which", return_value="pwsh.exe"),
            mock.patch.object(payload.subprocess, "check_output", return_value="100"),
            mock.patch.object(payload, "run_process", side_effect=fake_extract),
            mock.patch.dict(os.environ, {"SystemRoot": str(self.root)}),
            self.assertRaisesRegex(RuntimeError, "fixture failure"),
            payload.msi_payload(
                self.root / "fixture.msi",
                parent,
                self.root / "size.ps1",
                floor=0,
                cushion=0,
            ) as extracted,
        ):
            self.assertEqual((extracted / "demo.exe").read_bytes(), b"synthetic")
            raise RuntimeError("fixture failure")
        self.assertEqual(len(seen), 1)
        self.assertFalse(seen[0].exists())

    def test_missing_powershell_and_oversized_msi_fail_before_extraction(self) -> None:
        with (
            mock.patch.object(payload.shutil, "which", return_value=None),
            self.assertRaises(ValueError),
            payload.msi_payload(self.root / "a.msi", self.root, self.root / "size.ps1"),
        ):
            pass
        with (
            mock.patch.object(payload.shutil, "which", return_value="pwsh.exe"),
            mock.patch.object(payload.subprocess, "check_output", return_value="101"),
            mock.patch.object(payload, "run_process") as run,
            self.assertRaises(ValueError),
            payload.msi_payload(
                self.root / "a.msi",
                self.root,
                self.root / "size.ps1",
                floor=0,
                cushion=0,
                limit=100,
            ),
        ):
            pass
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
