"""Hash-bound upstream CMake with controlled Python/config metadata; no actual Python extension or GPU is built here."""

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
FIXTURE = ROOT / "linux/scripts/tests/fixtures/migraphx-python"


class MigraphxPythonSelectionTests(unittest.TestCase):
    """The original enumeration stops at3.14; the correction must use one explicit interpreter and its paired config."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="MIGraphX Python selection ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.original = self.root / "original source"
        (self.original / "cmake").mkdir(parents=True)
        raw = (FIXTURE / "PythonModules.cmake.txt").read_bytes()
        metadata = json.loads((FIXTURE / "source.json").read_text())
        self.assertEqual(metadata["commit"], "95672916ed289d4be9d230a9be732e1bbad97e8c")
        self.assertEqual(hashlib.sha256(raw).hexdigest(), metadata["sha256"])
        self.module = self.original / "cmake/PythonModules.cmake"
        self.module.write_bytes(raw)
        self.prefix = self.root / "paired Python prefix"
        (self.prefix / "include").mkdir(parents=True)
        (self.prefix / "bin").mkdir()
        self.config = self.prefix / "bin/python3.15-config"
        self.python = self.root / "selected python"
        self.shadow = self.root / "PATH shadow"
        self.shadow.mkdir()
        self.calls = self.root / "calls"
        self.config.write_text("#!" + sys.executable + "\n" + r"""
import os,sys
flag=sys.argv[1]
with open(os.environ["CALLS"],"a") as log: log.write("config:"+flag+"\n")
values={"--prefix":os.environ["PAIRED_PREFIX"],"--extension-suffix":".cpython-315-selection-test.so",
        "--includes":"-I"+__import__("shlex").quote(os.environ["PAIRED_PREFIX"]+"/include"),"--ldflags":""}
if os.environ.get("FOREIGN_CONFIG")==flag: print("/foreign")
elif os.environ.get("FOREIGN_HEADERS")==flag: print("-I/foreign/python/include")
elif os.environ.get("EMPTY_CONFIG")==flag: print("")
else: print(values[flag])
if os.environ.get("FAIL_CONFIG")==flag: sys.exit(43)
""")
        self.config.chmod(0o755)
        self.python.write_text("#!" + sys.executable + "\n" + r"""
import json,os,sys
if os.environ.get("BAD_JSON"): print("invalid-json")
else:
 print(json.dumps({"version":os.environ.get("REPORTED_VERSION","3.15.2"),
  "abi":"3.15","config":os.environ["PAIRED_CONFIG"],"prefix":os.environ["PAIRED_PREFIX"],
  "suffix":".cpython-315-selection-test.so", "include":os.environ["PAIRED_PREFIX"]+"/include",
  "platinclude":os.environ["PAIRED_PREFIX"]+"/include"}))
if os.environ.get("FAIL_PYTHON"): sys.exit(37)
""")
        self.python.chmod(0o755)
        for version in ["3.14", "3.15"]:
            file = self.shadow / ("python" + version + "-config")
            file.write_text("#!" + sys.executable + "\nimport os,sys\n"
                            'with open(os.environ["CALLS"],"a") as log: log.write("shadow:"+sys.argv[1]+"\\n")\n'
                            'values={"--prefix":os.environ["PAIRED_PREFIX"],"--extension-suffix":".foreign.so","--includes":"-I/usr/include","--ldflags":""}\n'
                            'print(values[sys.argv[1]])\n')
            file.chmod(0o755)
        package = self.root / "pybind package"
        package.mkdir()
        (package / "pybind11ConfigVersion.cmake").write_text(
            'set(PACKAGE_VERSION "3.1.0")\nset(PACKAGE_VERSION_COMPATIBLE TRUE)\n'
            'if(PACKAGE_FIND_VERSION STREQUAL PACKAGE_VERSION)\nset(PACKAGE_VERSION_EXACT TRUE)\nendif()\n')
        (package / "pybind11Config.cmake").write_text(
            'add_library(pybind11::module INTERFACE IMPORTED)\nadd_library(pybind11::lto INTERFACE IMPORTED)\n'
            'function(pybind11_strip name)\nendfunction()\n')
        self.package = package
        self.project = self.root / "project"
        self.project.mkdir()
        (self.project / "CMakeLists.txt").write_text(
            'cmake_minimum_required(VERSION 3.20)\nproject(Selection NONE)\ninclude("' + str(self.module) + '")\n'
            'if(NOT PYTHON_VERSIONS STREQUAL "3.15")\nmessage(FATAL_ERROR "Selected ABI mismatch: ${PYTHON_VERSIONS}")\nendif()\n'
            'file(WRITE "${CMAKE_BINARY_DIR}/selected.txt" "${PYTHON_CONFIG_3.15}\\n${MIGRAPHX_SELECTED_PYTHON_EXECUTABLE}\\n")\n')
        self.env = dict(os.environ, LC_ALL="C", CALLS=str(self.calls), PAIRED_PREFIX=str(self.prefix),
                        PAIRED_CONFIG=str(self.config), PATH=str(self.shadow) + os.pathsep + os.environ["PATH"])
        self.number = 0

    def apply(self) -> None:
        result = subprocess.run(["bash", str(ROOT / "linux/scripts/01-core/apply-patch.sh"),
                                 str(ROOT / "linux/scripts/patches/migraphx/002-select-pinned-python.patch"), str(self.original)],
                                capture_output=True, text=True, check=False, timeout=15, env=self.env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def configure(self, extra: list[str] | None = None) -> tuple[subprocess.CompletedProcess[str], Path]:
        self.number += 1
        build = self.root / ("build " + str(self.number))
        argv = ["cmake", "-S", str(self.project), "-B", str(build),
                "-DPython_EXECUTABLE=" + str(self.python), "-Dpybind11_DIR=" + str(self.package),
                "-DMIGRAPHX_REQUIRED_PYTHON_VERSION=3.15.2", "-DMIGRAPHX_REQUIRED_PYBIND11_VERSION=3.1.0"]
        result = subprocess.run([*argv, *(extra or [])], capture_output=True, text=True, check=False, timeout=20, env=self.env)
        self.assertNotIn("Parse error", result.stdout + result.stderr)
        return result, build

    def test_original_fails_named_ABI_assertion_corrected_uses_paired_config(self) -> None:
        original, _build = self.configure()
        self.assertNotEqual(original.returncode, 0, original.stdout + original.stderr)
        self.assertIn("Selected ABI mismatch", original.stdout + original.stderr)
        self.assertIn("shadow:", self.calls.read_text())
        self.calls.unlink()
        self.apply()
        fixed, build = self.configure(["-DPYTHON_CONFIG_3.15=" + str(self.shadow / "python3.15-config")])
        self.assertEqual(fixed.returncode, 0, fixed.stdout + fixed.stderr)
        self.assertEqual((build / "selected.txt").read_text().splitlines(), [str(self.config), str(self.python)])
        self.assertNotIn("shadow:", self.calls.read_text())

    def test_paired_config_raw_failures_and_wrong_prefix_or_suffix_refuse(self) -> None:
        self.apply()
        for name, values in [("FAIL_CONFIG", ["--prefix", "--extension-suffix", "--includes"]),
                             ("FOREIGN_CONFIG", ["--prefix", "--extension-suffix", "--includes"]),
                             ("FOREIGN_HEADERS", ["--includes"]), ("EMPTY_CONFIG", ["--includes"])]:
            for value in values:
                self.env[name] = value
                result, _build = self.configure()
                self.assertNotEqual(result.returncode, 0, (name, value, result.stdout, result.stderr))
            self.env.pop(name)

    def test_failed_interpreter_invalid_JSON_or_wrong_pin_refuses(self) -> None:
        self.apply()
        for name, value in [("FAIL_PYTHON", "1"), ("BAD_JSON", "1"), ("REPORTED_VERSION", "3.14.4")]:
            self.env[name] = value
            result, _build = self.configure()
            self.assertNotEqual(result.returncode, 0, (name, result.stdout, result.stderr))
            self.env.pop(name)

    def test_missing_paired_config_or_selected_headers_cannot_fall_back(self) -> None:
        self.apply()
        self.env["PAIRED_CONFIG"] = str(self.root / "missing config")
        result, _build = self.configure()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.calls.exists())
        self.env["PAIRED_CONFIG"] = str(self.config)
        (self.project / "CMakeLists.txt").write_text(
            'cmake_minimum_required(VERSION 3.20)\nproject(Selection NONE)\ninclude("' + str(self.module) + '")\n')
        result, _build = self.configure(["-DPYTHON_DISABLE_VERSIONS=3.15"])
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Selected Python headers were not configured", result.stdout + result.stderr)

    def test_inexact_pybind_or_missing_required_pins_refuse(self) -> None:
        self.apply()
        for extra in [["-DMIGRAPHX_REQUIRED_PYBIND11_VERSION=3.0.0"],
                      ["-DMIGRAPHX_REQUIRED_PYBIND11_VERSION="], ["-DMIGRAPHX_REQUIRED_PYTHON_VERSION="],
                      ["-DPython_EXECUTABLE="]]:
            result, _build = self.configure(extra)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        version = self.package / "pybind11ConfigVersion.cmake"
        version.write_text(version.read_text().replace('PACKAGE_VERSION "3.1.0"', 'PACKAGE_VERSION "3.2.0"'))
        result, _build = self.configure()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
