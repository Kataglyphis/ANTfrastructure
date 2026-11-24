"""Compile the canonical C++ helper with fake API callbacks; no native ORT ABI or GPU inference proof."""

from __future__ import annotations

import json
import os
import re
import shlex
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
POLICY_REPORT = re.compile(r"external native plugin policy checks: (\d+)\nnative plugin policy checks: (\d+)\n")


class NativeCompileError(RuntimeError):
    """Compiler and linker failures cannot count as semantic mutation evidence."""


def compile_fixture(source: Path, executable: Path, include_dir: Path) -> None:
    compiler = shlex.split(os.environ.get("CXX", "c++"))
    object_file = executable.with_suffix(".o")
    commands = (
        [*compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror", "-pthread",
         "-I", str(include_dir), "-c", str(source), "-o", str(object_file)],
        [*compiler, "-pthread", str(object_file), "-o", str(executable)],
    )
    for command in commands:
        result = subprocess.run(command, check=False, capture_output=True, text=True, timeout=90)
        if result.returncode:
            raise NativeCompileError(f"Native fixture command failed ({result.returncode}): {command}\n{result.stdout}{result.stderr}")


def run_fixture(executable: Path, directory: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(executable), str(directory), *args], capture_output=True,
                          text=True, check=False, timeout=20)


def assert_native_policy(test: unittest.TestCase, result: subprocess.CompletedProcess[str]) -> None:
    test.assertEqual(result.returncode, 0, result.stdout + result.stderr)
    match = POLICY_REPORT.fullmatch(result.stdout)
    test.assertIsNotNone(match, result.stdout)
    assert match is not None
    test.assertGreaterEqual(int(match.group(1)), 28)
    test.assertGreaterEqual(int(match.group(2)), 50)


def expect_semantic_mutant(test: unittest.TestCase, result: subprocess.CompletedProcess[str]) -> None:
    if result.returncode not in (0, 1):
        raise ValueError("Abnormal native fixture exit cannot prove a semantic mutation")
    if result.returncode == 1 and not result.stderr.startswith("CHECK failed:"):
        raise ValueError("Missing native assertion diagnostic")
    if result.returncode == 0 and POLICY_REPORT.fullmatch(result.stdout) is None:
        raise ValueError("Missing native check-count report")
    with test.assertRaises(AssertionError):
        assert_native_policy(test, result)


class NativeFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workspace = tempfile.TemporaryDirectory(prefix="ort-native-plugin-")
        cls.addClassCleanup(cls.workspace.cleanup)
        cls.root = Path(cls.workspace.name)


class NativePluginTests(NativeFixtureTests):
    """A compiled policy fixture and a mandatory failing assertion control."""

    @classmethod
    def setUpClass(cls) -> None:
        """Keep the executables alive only for these bounded tests."""
        super().setUpClass()
        cls.executable = cls.root / "native-plugin-policy"
        cls.io_executable = cls.root / "tensor-io"
        for source, executable in (("ort_plugin_eps_test.cpp", cls.executable), ("ort_tensor_io_test.cpp", cls.io_executable)):
            compile_fixture(ROOT / "shared/native/tests" / source, executable, ROOT / "shared/native")

    def test_native_registration_policy(self) -> None:
        """Verify the unmodified C++ API policy fixture performs nonvacuous checks."""
        result = run_fixture(self.executable, self.root / "policy")
        assert_native_policy(self, result)
        print(result.stdout, end="")

    def test_assertion_control_fails(self) -> None:
        """A deliberately false assertion must be observable independently of production code."""
        result = run_fixture(self.executable, self.root / "control", "--fail-control")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("CHECK failed: negative control", result.stderr)
        self.assertNotIn("native plugin policy checks:", result.stdout)

    def test_native_tensor_transport(self) -> None:
        result = run_fixture(self.io_executable, self.root / "tensor-data")
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
        result = run_fixture(self.io_executable, self.root / "tensor-control", "--fail-control")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Tensor IO assertion failed", result.stderr)
        self.assertNotIn("TENSOR-IO PASS:", result.stdout)


class NativeMutationControls(NativeFixtureTests):
    """Each new native mutation must compile and fail an assertion or independent count."""

    @classmethod
    def setUpClass(cls) -> None:
        super().setUpClass()
        cls.executable = cls.root / "unmodified-policy"
        compile_fixture(ROOT / "shared/native/tests/ort_plugin_eps_test.cpp", cls.executable, ROOT / "shared/native")
        rows = json.loads((ROOT / "linux/scripts/tests/ort-plugin-native-external-mutations.json").read_text())
        cls.cases = [row for row in rows if row["target"].startswith("shared/native/")]

    def build_mutant(self, row: dict[str, str]) -> Path:
        directory = self.root / row["id"]
        directory.mkdir()
        for name in ("shared/native/ort_plugin_eps.hpp", "shared/native/tests/ort_plugin_eps_test.cpp"):
            (directory / Path(name).name).write_bytes((ROOT / name).read_bytes())
        target = directory / Path(row["target"]).name
        text = target.read_text()
        self.assertEqual(text.count(row["find"]), 1, row["id"])
        target.write_text(text.replace(row["find"], row["replace"], 1))
        executable = directory / "mutant-policy"
        compile_fixture(directory / "ort_plugin_eps_test.cpp", executable, directory)
        return executable

    def test_new_mutants_fail_semantically(self) -> None:
        self.assertGreaterEqual(len(self.cases), 9)
        executed = 0
        for row in self.cases:
            with self.subTest(mutation=row["id"]):
                executable = self.build_mutant(row)
                result = run_fixture(executable, executable.parent / "data")
                expect_semantic_mutant(self, result)
                executed += 1
        self.assertEqual(executed, len(self.cases))
        print(f"native mutation controls: {executed} semantic cases")

    def test_unchanged_policy_cannot_count_as_red(self) -> None:
        result = run_fixture(self.executable, self.root / "unchanged")
        with self.assertRaisesRegex(AssertionError, "AssertionError not raised"):
            expect_semantic_mutant(self, result)

    def assert_compile_rejected(self, name: str, text: str) -> None:
        source = self.root / f"{name}.cpp"
        source.write_text(text)
        with self.assertRaises(NativeCompileError):
            compile_fixture(source, self.root / name, self.root)

    def test_warning_rejection_cannot_count_as_red(self) -> None:
        self.assert_compile_rejected("warning", "int value(int unused) { return 0; }\nint main() { return value(1); }\n")

    def test_link_rejection_cannot_count_as_red(self) -> None:
        self.assert_compile_rejected("link", "void missing();\nint main() { missing(); }\n")

    def test_abnormal_exit_cannot_count_as_red(self) -> None:
        with self.assertRaisesRegex(ValueError, "Abnormal"):
            expect_semantic_mutant(self, subprocess.CompletedProcess([], -11, "", ""))

    def test_unexplained_exit_cannot_count_as_red(self) -> None:
        with self.assertRaisesRegex(ValueError, "assertion diagnostic"):
            expect_semantic_mutant(self, subprocess.CompletedProcess([], 1, "", "loader failed"))

    def test_missing_report_cannot_count_as_red(self) -> None:
        with self.assertRaisesRegex(ValueError, "check-count report"):
            expect_semantic_mutant(self, subprocess.CompletedProcess([], 0, "invalid output", ""))


if __name__ == "__main__":
    selection = "NativePluginTests"
    if "--mutation-controls" in sys.argv:
        sys.argv.remove("--mutation-controls")
        selection = "NativeMutationControls"
    unittest.main(defaultTest=selection)
