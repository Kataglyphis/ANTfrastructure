"""Compile the canonical C++ helper with fake API callbacks; no native ORT ABI or GPU inference proof."""

from __future__ import annotations

import os
import re
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class NativePluginTests(unittest.TestCase):
    """A compiled policy fixture and a mandatory failing assertion control."""

    @classmethod
    def setUpClass(cls) -> None:
        """Keep the executable alive only for these two bounded tests."""
        cls.workspace = tempfile.TemporaryDirectory(prefix="ort-native-plugin-")
        cls.addClassCleanup(cls.workspace.cleanup)
        cls.root = Path(cls.workspace.name)
        cls.executable = cls.root / "native-plugin-policy"
        compiler = shlex.split(os.environ.get("CXX", "c++"))
        subprocess.run(
            [*compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror", "-pthread",
             "-I", str(ROOT / "shared/native"), str(ROOT / "shared/native/tests/ort_plugin_eps_test.cpp"),
             "-o", str(cls.executable)],
            check=True, capture_output=True, text=True, timeout=90,
        )

    def test_native_registration_policy(self) -> None:
        """Verify the unmodified C++ API policy fixture performs nonvacuous checks."""
        result = subprocess.run([str(self.executable), str(self.root / "policy")], capture_output=True,
                                text=True, check=False, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        match = re.fullmatch(r"native plugin policy checks: (\d+)\n", result.stdout)
        self.assertIsNotNone(match, result.stdout)
        assert match is not None
        self.assertGreaterEqual(int(match.group(1)), 50)

    def test_assertion_control_fails(self) -> None:
        """A deliberately false assertion must be observable independently of production code."""
        result = subprocess.run([str(self.executable), str(self.root / "control"), "--fail-control"],
                                capture_output=True, text=True, check=False, timeout=20)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("CHECK failed: negative control", result.stderr)
        self.assertNotIn("native plugin policy checks:", result.stdout)


if __name__ == "__main__":
    unittest.main()
