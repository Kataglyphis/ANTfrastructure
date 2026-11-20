"""Synthetic child/loader fixtures test the real driver and refusal policy, never real ORT or GPU inference."""
from __future__ import annotations

import copy
import hashlib
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import ModuleType
from typing import cast
from unittest.mock import patch

from ort_webgpu_wasm_hook_tests import WasmHookTests
from wasm_proof_fixture import install_node_fixture

g = cast(ModuleType, globals()["g"])
REAL_NODE = shutil.which("node")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class WasmRuntimeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.prefix = self.root / "products"
        self.prefix.mkdir()
        self.wasm = self.prefix / "original.wasm"
        self.loader = self.prefix / "original.mjs"
        self.wasm.write_bytes(b"\0asm\x01\0\0\0")
        self.loader.write_text("synthetic loader bytes")
        self.product = {"path": self.wasm.name, "sha256": digest(self.wasm),
                        "loader": {"path": self.loader.name, "sha256": digest(self.loader)}}
        self.source = {"ref": "v1.31.1", "revision": "1" * 40}
        node_fixture = install_node_fixture(self.root / "bin")
        self.enterContext(patch.dict(os.environ, {"PATH": str(node_fixture) + os.pathsep + os.environ["PATH"]}))
        self.recipe = {name: digest(g.HERE / name) for name in
                       ("webgpu-factory-probe/probe.c", "webgpu-factory-probe/wasm.cmake",
                        "webgpu-factory-probe/run-wasm.mjs", "webgpu-factory-probe/LICENSE", "ort-webgpu-wasm-runtime.py")}

    def proof(self, flavor: str = "asyncify") -> dict:
        return {"schema_version": 1, "flavor": flavor, "source": self.source, "product": self.product,
                "recipe": self.recipe, "node_sha256": "c" * 64, "returncode": 0, "timed_out": False,
                "stdout": 'WEBGPU-WASM-NODE: {"version":"v26.13.0","jspiSupported":true}\n'
                          "WEBGPU-WASM OK: mode=ON api=31 version=1.31.1\n",
                "stderr": "", "unchanged_inputs": True}

    def validate(self, proof: dict, flavor: str = "asyncify") -> None:
        g.validate(proof, flavor, self.product, self.source, digest)

    def test_both_flavors_require_current_recipe_and_real_child_verdict_fields(self) -> None:
        self.assertEqual(g.recipe(digest), self.recipe)
        for flavor in ("asyncify", "jspi"):
            self.validate(self.proof(flavor), flavor)
        for key, value in (("schema_version", 2), ("flavor", "jspi"), ("source", {}),
                           ("product", {}), ("recipe", {}), ("returncode", 19), ("returncode", False),
                           ("timed_out", True), ("unchanged_inputs", False), ("node_sha256", "bad")):
            proof = copy.deepcopy(self.proof())
            proof[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                self.validate(proof)

    def test_success_requires_one_precise_c_marker_with_no_inner_failure(self) -> None:
        baseline = self.proof()
        for output in ("", baseline["stdout"] * 2,
                       baseline["stdout"] + "WEBGPU-WASM OK: mode=ON api=31 version=1.31.1\n",
                       baseline["stdout"].replace("mode=ON", "mode=OFF"),
                       baseline["stdout"].replace("api=31", "api=0"),
                       baseline["stdout"].replace("version=1.31.1", "version=1.31.0"),
                       baseline["stdout"] + "WEBGPU-WASM FAIL: swallowed failure\n"):
            proof = {**baseline, "stdout": output}
            with self.subTest(output=output), self.assertRaises(ValueError):
                self.validate(proof)
        for error in ("WEBGPU-WASM FAIL: negative control", "WEBGPU-WASM-RUNTIME FAIL: exception"):
            with self.subTest(error=error), self.assertRaises(ValueError):
                self.validate({**baseline, "stderr": error})
        with self.assertRaises(ValueError):
            self.validate({**baseline, "stderr": "x" * (2 * 1024 * 1024 + 1)})

    def test_node_identity_and_actual_jspi_support_are_required(self) -> None:
        baseline = self.proof("jspi")
        duplicate = baseline["stdout"] + 'WEBGPU-WASM-NODE: {"version":"v26.13.0","jspiSupported":true}\n'
        with self.assertRaises(ValueError):
            self.validate({**baseline, "stdout": duplicate}, "jspi")
        for metadata in ("", "invalid JSON", '{"version":"fixture","jspiSupported":true}',
                         '{"version":"v26.13.0","jspiSupported":false}',
                         '{"version":"v26.13.0","jspiSupported":"true"}'):
            output = "WEBGPU-WASM OK: mode=ON api=31 version=1.31.1\n"
            if metadata:
                output += "WEBGPU-WASM-NODE: " + metadata + "\n"
            with self.subTest(metadata=metadata), self.assertRaises(ValueError):
                self.validate({**baseline, "stdout": output}, "jspi")

    def test_successful_child_retains_exact_recipe_source_products_and_node_identity(self) -> None:
        for flavor in ("asyncify", "jspi"):
            proof = g.run_probe(self.prefix, flavor, self.product, self.source, digest)
            self.assertEqual(proof["recipe"], self.recipe)
            self.assertEqual(proof["source"], self.source)
            self.assertEqual(proof["product"], self.product)
            self.assertEqual(proof["node_sha256"], digest(self.root / "bin/node"))
            self.assertEqual(proof["returncode"], 0)
            self.validate(proof, flavor)

    def test_run_preserves_raw_child_status_output_and_timeout_before_validation(self) -> None:
        output = self.proof()["stdout"]
        for result in (subprocess.CompletedProcess([], 47, output, "raw diagnostic"),
                       subprocess.TimeoutExpired(["node"], 120, output=output.encode(), stderr=b"timeout diagnostic")):
            with patch.object(g.subprocess, "run", side_effect=result if isinstance(result, Exception) else None,
                              return_value=result) as child:
                proof = g.run_probe(self.prefix, "asyncify", self.product, self.source, digest)
                self.assertEqual(child.call_args.kwargs["timeout"], 120)
            self.assertEqual(proof["stdout"], output)
            self.assertIn("diagnostic", proof["stderr"])
            self.assertEqual(proof["returncode"], None if isinstance(result, Exception) else 47)
            with self.assertRaises(ValueError):
                self.validate(proof)

    def test_changed_loader_wasm_or_node_is_not_a_successful_runtime_proof(self) -> None:
        node = self.root / "bin/node"
        for target in (self.loader, self.wasm, node):
            before = target.read_bytes()
            def changed(*args: object, target: Path = target, saved: bytes = before,
                        **kwargs: object) -> subprocess.CompletedProcess[str]:
                target.write_bytes(saved + b"changed")
                return subprocess.CompletedProcess([], 0, self.proof()["stdout"], "")
            with patch.object(g.subprocess, "run", side_effect=changed):
                proof = g.run_probe(self.prefix, "asyncify", self.product, self.source, digest)
            self.assertFalse(proof["unchanged_inputs"])
            with self.assertRaises(ValueError):
                self.validate(proof)
            target.write_bytes(before)

    def test_disappearing_input_retains_the_raw_child_result_and_failed_verdict(self) -> None:
        def disappeared(*args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
            self.loader.unlink()
            return subprocess.CompletedProcess([], 0, self.proof()["stdout"], "raw child diagnostic")
        with patch.object(g.subprocess, "run", side_effect=disappeared):
            proof = g.run_probe(self.prefix, "asyncify", self.product, self.source, digest)
        self.assertEqual(proof["returncode"], 0)
        self.assertEqual(proof["stderr"], "raw child diagnostic")
        self.assertFalse(proof["unchanged_inputs"])
        with self.assertRaises(ValueError):
            self.validate(proof)

    def run_driver(self, body: str, flavor: str = "asyncify", node_args: tuple[str, ...] = ()) -> subprocess.CompletedProcess[str]:
        if REAL_NODE is None:
            self.fail("The WASM driver fixture requires Node")
        self.loader.write_text(body)
        return subprocess.run([REAL_NODE, *node_args, str(g.HERE / "webgpu-factory-probe/run-wasm.mjs"),
                               str(self.loader), str(self.wasm), flavor],
                              capture_output=True, text=True, check=False, timeout=15)

    def test_real_node_driver_reads_original_bytes_and_invokes_the_export_once(self) -> None:
        result = self.run_driver("""export default async options => {
          if (options.numThreads !== 1 || options.wasmBinary.length !== 8) throw Error('wrong inputs');
          return {_OrtWebGpuFactoryProbe: async mode => {
            if (mode !== 1) throw Error('wrong mode');
            options.print('WEBGPU-WASM OK: mode=ON api=31 version=1.31.1');
            return 0;
          }};
        };""")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("WEBGPU-WASM OK:"), 1)
        self.assertEqual(result.stderr, "")

    def test_real_node_driver_refuses_missing_wrong_status_and_throwing_exports(self) -> None:
        for body in ("export default async () => ({});",
                     "export default async () => ({_OrtWebGpuFactoryProbe: () => '0'});",
                     "export default async () => ({_OrtWebGpuFactoryProbe: () => 17});",
                     "export default async () => ({_OrtWebGpuFactoryProbe: () => {throw Error('fixture');}});",
                     "throw Error('initialization fixture');"):
            with self.subTest(body=body):
                result = self.run_driver(body)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("WEBGPU-WASM-RUNTIME FAIL:", result.stderr)

    def test_missing_jspi_feature_fixture_refuses_before_the_loader_runs(self) -> None:
        fixture = Path(__file__).parent / "fixtures/webgpu-native/without-jspi.cjs"
        result = self.run_driver("throw Error('loader should not run');", "jspi", ("--require", str(fixture)))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not support JSPI", result.stderr)
        self.assertNotIn("loader should not run", result.stderr)

    def test_real_node_jspi_capability_is_checked_without_a_gpu_mock(self) -> None:
        if REAL_NODE is None:
            self.fail("The WASM driver fixture requires Node")
        capability = subprocess.run([REAL_NODE, "-p", "typeof WebAssembly.Suspending"],
                                    capture_output=True, text=True, check=True, timeout=10).stdout.strip()
        result = self.run_driver("export default async () => ({_OrtWebGpuFactoryProbe: () => 0});", "jspi")
        self.assertEqual(result.returncode == 0, capability == "function", result.stderr)
        if capability != "function":
            self.assertIn("does not support JSPI", result.stderr)


def load_tests(loader: unittest.TestLoader, _tests: unittest.TestSuite, _pattern: str | None) -> unittest.TestSuite:
    return unittest.TestSuite(loader.loadTestsFromTestCase(case) for case in (WasmRuntimeTests, WasmHookTests))


if __name__ == "__main__":
    unittest.main(argv=[__file__], verbosity=2)
