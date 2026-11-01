#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
"""Exercise administrative extraction of a synthetic MSI, not application installation."""

from __future__ import annotations

import importlib
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "shared/python"))
payload = importlib.import_module("windows_installer_payload")


class RealMsiFixture(unittest.TestCase):
    @unittest.skipUnless(
        os.name == "nt" and os.environ.get("GPU_TEST_MSI"),
        "requires a synthetic MSI on Windows",
    )
    def test_extracts_payload_and_cleans_up(self) -> None:
        package = Path(os.environ["GPU_TEST_MSI"]).resolve(strict=True)
        size = ROOT / "windows/scripts/diagnostics/Get-MsiPayloadSize.ps1"
        for prefix in ("gpu-payload-", "gpu payload with spaces "):
            with (
                self.subTest(prefix=prefix),
                tempfile.TemporaryDirectory(prefix=prefix) as temp,
            ):
                with payload.msi_payload(
                    package, Path(temp), size, floor=0, cushion=0
                ) as extracted:
                    paths = list(extracted.rglob("gpu-fixture.txt"))
                    self.assertEqual(len(paths), 1)
                    self.assertEqual(
                        paths[0].read_text(encoding="ascii"), "gpu-fixture"
                    )
                self.assertFalse(extracted.exists())


if __name__ == "__main__":
    unittest.main()
