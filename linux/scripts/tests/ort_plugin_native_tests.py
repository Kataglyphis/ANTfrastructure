"""Compile the canonical C++ helper with fake API callbacks; no native ORT ABI or GPU inference proof."""

from __future__ import annotations

import json
import os
import re
import shlex
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class NativePluginTests(unittest.TestCase):
    """A compiled policy fixture and a mandatory failing assertion control."""

    @classmethod
    def setUpClass(cls) -> None:
        """Keep the executables alive only for these bounded tests."""
        cls.workspace = tempfile.TemporaryDirectory(prefix="ort-native-plugin-")
        cls.addClassCleanup(cls.workspace.cleanup)
        cls.root = Path(cls.workspace.name)
        cls.executable = cls.root / "native-plugin-policy"
        cls.io_executable = cls.root / "tensor-io"
        compiler = shlex.split(os.environ.get("CXX", "c++"))
        for source, executable in (("ort_plugin_eps_test.cpp", cls.executable), ("ort_tensor_io_test.cpp", cls.io_executable)):
            subprocess.run(
                [*compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror", "-pthread",
                 "-I", str(ROOT / "shared/native"), str(ROOT / "shared/native/tests" / source),
                 "-o", str(executable)],
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

    def test_native_tensor_transport(self) -> None:
        result = subprocess.run([str(self.io_executable), str(self.root / "tensor-data")], capture_output=True,
                                text=True, check=False, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        match = re.fullmatch(r"TENSOR-IO PASS: (\d+) checks\n", result.stdout)
        self.assertIsNotNone(match, result.stdout)
        assert match is not None
        self.assertGreaterEqual(int(match.group(1)), 25)
        expected = struct.pack("<3f", 1.1, -0.0, 2.0)
        for kind in ("cpu", "gpu"):
            for run in (1, 2):
                directory = self.root / "tensor-data" / kind
                metadata = json.loads((directory / f"run-{run}.json").read_text())
                self.assertEqual(set(metadata), {"schema_version", "run", "input", "output"})
                self.assertEqual(metadata["schema_version"], 1)
                self.assertEqual(metadata["run"], run)
                for name, shape in (("input", [1, 3, 1, 1]), ("output", [3])):
                    filename = f"run-{run}-{name}.f32le"
                    self.assertEqual(metadata[name], {"path": filename, "dtype": "float32", "byte_order": "little", "shape": shape})
                    self.assertEqual((directory / filename).read_bytes(), expected)

    def test_tensor_assertion_control_fails(self) -> None:
        result = subprocess.run([str(self.io_executable), str(self.root / "tensor-control"), "--fail-control"],
                                capture_output=True, text=True, check=False, timeout=20)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Tensor IO assertion failed", result.stderr)
        self.assertNotIn("TENSOR-IO PASS:", result.stdout)


if __name__ == "__main__":
    unittest.main()
