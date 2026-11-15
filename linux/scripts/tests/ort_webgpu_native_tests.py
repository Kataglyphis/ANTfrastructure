"""Run the real C probe through a fake C ABI and checked native receipts; no real ORT or GPU."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

import ort_webgpu_build_proof_tests as fixture

PROBE = Path(sys.argv[4]).resolve()
SUBJECT = Path(sys.argv[5]).resolve()
FAKE_CORE = Path(sys.argv[2]).resolve()
CLOSE_FAILURE = Path(sys.argv[6]).resolve()
spec = importlib.util.spec_from_file_location("native_runtime_proof", SUBJECT)
assert spec is not None and spec.loader is not None
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class NativeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.built = fixture.BuildProofTests()
        self.built.setUp()
        self.addCleanup(self.built.doCleanups)
        self.root, self.prefix = self.built.root, self.built.prefix
        self.built.passed()
        (self.prefix / "bin").mkdir()
        self.probe = self.prefix / "bin/ort-webgpu-factory-probe"
        shutil.copy2(PROBE, self.probe)
        self.trace = self.root / "native-calls"
        self.environment = {**os.environ, "WEBGPU_NATIVE_LOG": str(self.trace), "WEBGPU_NATIVE_SCENARIO": "static"}
        self.enterContext(patch.dict(os.environ, self.environment))

    def run_probe(self, scenario: str = "static", mode: str = "ON") -> subprocess.CompletedProcess[str]:
        return subprocess.run([str(PROBE), str(FAKE_CORE), mode], capture_output=True, text=True, check=False,
                              env={**self.environment, "WEBGPU_NATIVE_SCENARIO": scenario}, timeout=10)

    def test_real_c_api_calls_and_cleanup_for_static_and_off_modes(self) -> None:
        for mode, scenario in (("ON", "static"), ("OFF", "off")):
            with self.subTest(mode=mode):
                self.trace.unlink(missing_ok=True)
                result = self.run_probe(scenario, mode)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(result.stdout.startswith(f"WEBGPU-NATIVE OK: mode={mode} api=31 version=1.31.1-fixture"))
                calls = self.trace.read_text().splitlines()
                self.assertEqual(calls[:4], ["GETAPI", "PROVIDERS", "RELEASEPROVIDERS", "CREATEENV"])
                self.assertEqual(calls.count("UNREGISTER"), 2)
                self.assertEqual(calls.count("RELEASESTATUS"), 1 if mode == "ON" else 2)
                self.assertEqual(calls[-2:], ["RELEASEENV", "DLCLOSE"])

    def test_legacy_and_invalid_provider_lists_never_initialize_an_environment(self) -> None:
        for scenario in ("legacy", "duplicate-cpu", "no-cpu", "null-providers", "empty-list", "empty-entry", "too-many", "provider-failure", "release-failure"):
            with self.subTest(scenario=scenario):
                self.trace.unlink(missing_ok=True)
                result = self.run_probe(scenario)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("WEBGPU-NATIVE OK:", result.stdout)
                calls = self.trace.read_text().splitlines()
                self.assertNotIn("CREATEENV", calls)
                self.assertEqual(calls[-1], "DLCLOSE")
                if scenario == "release-failure":
                    self.assertIn("RELEASESTATUS", calls)

    def test_api_and_environment_failures_never_report_success(self) -> None:
        for scenario in ("no-base", "no-api", "no-unregister", "no-version", "create-failure", "null-env"):
            with self.subTest(scenario=scenario):
                self.trace.unlink(missing_ok=True)
                result = self.run_probe(scenario)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("WEBGPU-NATIVE OK:", result.stdout)
                calls = self.trace.read_text().splitlines()
                self.assertNotIn("UNREGISTER", calls)
                self.assertEqual(calls[-1], "DLCLOSE")

    def test_registration_and_negative_control_failures_release_environment_and_status(self) -> None:
        for scenario in ("first-missing", "repeat-success", "wrong-message", "wrong-code", "null-message"):
            with self.subTest(scenario=scenario):
                self.trace.unlink(missing_ok=True)
                result = self.run_probe(scenario)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("WEBGPU-NATIVE OK:", result.stdout)
                self.assertEqual(self.trace.read_text().splitlines()[-2:], ["RELEASEENV", "DLCLOSE"])
        self.assertNotEqual(self.run_probe("static", "OFF").returncode, 0)

    def test_loader_cleanup_failure_cannot_report_success(self) -> None:
        result = subprocess.run([str(PROBE), str(FAKE_CORE), "ON"], capture_output=True, text=True, check=False,
                                env={**self.environment, "LD_PRELOAD": str(CLOSE_FAILURE)}, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dlclose failed", result.stderr)
        self.assertNotIn("WEBGPU-NATIVE OK:", result.stdout)
        self.assertIn("RELEASEENV", self.trace.read_text())

    def test_invalid_usage_and_unloadable_core_fail_without_success(self) -> None:
        for args in ([], ["relative.so", "ON"], [str(FAKE_CORE), "maybe"], [str(self.root / "absent.so"), "ON"]):
            result = subprocess.run([str(PROBE), *args], capture_output=True, text=True, check=False, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("WEBGPU-NATIVE OK:", result.stdout)

    def test_runtime_binds_every_requested_native_prefix_without_importing_python(self) -> None:
        with patch.object(runtime.importlib, "import_module", side_effect=AssertionError("Python import is forbidden")):
            result = runtime.prove_native([self.prefix], "v1.31.1")
        self.assertEqual(result["phase"], "native")
        self.assertEqual(len(result["cores"]), 1)
        self.assertEqual(result["cores"][0]["probe_sha256"], hashlib.sha256(PROBE.read_bytes()).hexdigest())
        second = self.root / "second native prefix"
        shutil.copytree(self.prefix, second)
        self.assertEqual(len(runtime.prove_native([self.prefix, second], "v1.31.1")["cores"]), 2)
        (second / "bin/ort-webgpu-factory-probe").unlink()
        with self.assertRaises(OSError):
            runtime.prove_native([self.prefix, second], "v1.31.1")

    def test_runtime_native_only_off_receipt_still_requires_absence(self) -> None:
        self.built.write_config("OFF")
        for wheel in (self.prefix / "wheels").glob("*.whl"):
            wheel.unlink()
        self.built.passed(mode="OFF", without_wheel=True)
        with patch.dict(os.environ, {"WEBGPU_NATIVE_SCENARIO": "off"}):
            self.assertEqual(runtime.prove_native([self.prefix], "v1.31.1")["cores"][0]["mode"], "OFF")
        with self.assertRaisesRegex(ValueError, "probe failed"):
            runtime.prove_native([self.prefix], "v1.31.1")

    def test_runtime_rejects_source_core_and_probe_mismatches(self) -> None:
        with self.assertRaisesRegex(ValueError, "source ref"):
            runtime.prove_native([self.prefix], "foreign-ref")
        self.built.library.write_bytes(fixture.ELF + b"stale")
        with self.assertRaisesRegex(ValueError, "native core changed"):
            runtime.prove_native([self.prefix], "v1.31.1")
        self.built.library.write_bytes(fixture.ELF + b"native core")
        self.probe.write_text("#!/bin/sh\nexit 0\n")
        with self.assertRaisesRegex(ValueError, "not an ELF"):
            runtime.prove_native([self.prefix], "v1.31.1")
        self.probe.unlink()
        self.probe.symlink_to(PROBE)
        with self.assertRaises(ValueError):
            runtime.prove_native([self.prefix], "v1.31.1")

    def test_child_status_sentinels_and_changed_bytes_cannot_pass(self) -> None:
        for status, output, error in ((0, "", ""), (0, "WEBGPU-NATIVE OK: mode=OFF api=31", ""),
                                      (0, "WEBGPU-NATIVE OK: mode=ON one\nWEBGPU-NATIVE OK: mode=ON two", ""),
                                      (7, "WEBGPU-NATIVE OK: mode=ON one", ""),
                                      (0, "WEBGPU-NATIVE OK: mode=ON one", "WEBGPU-NATIVE FAIL: inner failure")):
            with (self.subTest(status=status, output=output, error=error),
                  patch.object(runtime.subprocess, "run", return_value=subprocess.CompletedProcess([], status, output, error)),
                  self.assertRaisesRegex(ValueError, "probe failed")):
                runtime.prove_native([self.prefix], "v1.31.1")
        for path in (self.probe, self.built.library):
            original = path.read_bytes()
            def changed(*args: object, target: Path = path, saved: bytes = original,
                        **kwargs: object) -> subprocess.CompletedProcess[str]:
                target.write_bytes(saved + b"changed")
                return subprocess.CompletedProcess([], 0, "WEBGPU-NATIVE OK: mode=ON fixture", "")
            with (patch.object(runtime.subprocess, "run", side_effect=changed), self.assertRaisesRegex(ValueError, "changed during")):
                runtime.prove_native([self.prefix], "v1.31.1")
            path.write_bytes(original)

    def test_native_cli_executes_without_python_bindings(self) -> None:
        result = subprocess.run([sys.executable, "-I", str(SUBJECT), "--phase", "native", "--prefix", str(self.prefix),
                                 "--source-ref", "v1.31.1"], capture_output=True, text=True, check=False, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        verdict = json.loads(result.stdout.removeprefix("WEBGPU-FACTORY OK: "))
        self.assertEqual(verdict["phase"], "native")


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)
