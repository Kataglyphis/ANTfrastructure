# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Check explicit empty-source CLI rules against synthetic ZIPs; no native binary or complete licence proof."""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path


class EmptySourceTests(unittest.TestCase):
    subject: Path
    fixture: Path

    def check(self, status: int, *arguments: str) -> None:
        result = subprocess.run(
            [
                sys.executable,
                "-I",
                str(self.subject),
                str(self.fixture / "app.zip"),
                *arguments,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)

    def test_explicit_selected_empty_member(self) -> None:
        rule = "app/source.patch=" + str(self.fixture / "empty.dll")
        self.check(0, "--require", rule, "--allow-empty", "app/source.patch")
        self.check(1, "--require", rule)

    def test_unselected_allowance(self) -> None:
        self.check(
            1,
            "--require",
            "app/shared.dll=" + str(self.fixture / "shared.dll"),
            "--allow-empty",
            "app/missing",
        )

    def test_duplicate_allowance(self) -> None:
        self.check(
            1,
            "--require",
            "app/shared.dll=" + str(self.fixture / "shared.dll"),
            "--allow-empty",
            "app/shared.dll",
            "--allow-empty",
            "app/shared.dll",
        )

    def test_one_allowance_cannot_permit_another_member(self) -> None:
        self.check(
            1,
            "--require",
            "app/shared.dll=" + str(self.fixture / "shared.dll"),
            "--require",
            "app/source.patch=" + str(self.fixture / "empty.dll"),
            "--allow-empty",
            "app/shared.dll",
        )

    def test_explicit_permission_keeps_exact_bytes(self) -> None:
        self.check(
            1,
            "--require",
            "app/source.patch=" + str(self.fixture / "provider.dll"),
            "--allow-empty",
            "app/source.patch",
        )


if __name__ == "__main__":
    EmptySourceTests.subject, EmptySourceTests.fixture = map(Path, sys.argv[1:3])
    unittest.main(argv=[sys.argv[0]], verbosity=2)
