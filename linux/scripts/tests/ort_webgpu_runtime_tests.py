"""Exercise product bindings and factory verdicts with stub bindings; no ORT or GPU runs."""
from __future__ import annotations

import hashlib
import importlib.machinery
import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path
from types import ModuleType
from unittest.mock import Mock, patch

import ort_webgpu_build_proof_tests as fixture

SUBJECT = Path(sys.argv[4]).resolve()
spec = importlib.util.spec_from_file_location("runtime_proof", SUBJECT)
assert spec is not None and spec.loader is not None
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class OrtFailure(Exception):
    pass


class StubBinding(ModuleType):
    Fail = OrtFailure
    unregister_execution_provider_library: Mock


class RuntimeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.built = fixture.BuildProofTests()
        self.built.setUp()
        self.addCleanup(self.built.doCleanups)
        self.root, self.prefix = self.built.root, self.built.prefix
        self.built.passed()
        self.built.wheel("free-threaded")
        self.built.passed("free-threaded")
        self.complete_delivery()
        self.extension = self.root / "site/onnxruntime/capi/onnxruntime_pybind11_state.so"
        self.extension.parent.mkdir(parents=True)
        self.binding = StubBinding("onnxruntime.capi.onnxruntime_pybind11_state")
        self.binding.Fail = OrtFailure
        self.select_phase("gil")
        self.binding.unregister_execution_provider_library = Mock(side_effect=[None, OrtFailure(runtime.MISSING)])
        self.enterContext(patch.object(runtime.importlib, "import_module", return_value=self.binding))
        self.enterContext(patch.object(runtime.sysconfig, "get_config_var", side_effect=lambda key: self.ft))
        self.enterContext(patch.object(runtime.sys, "_is_gil_enabled", create=True, side_effect=lambda: self.gil))

    def receipt(self) -> dict:
        return json.loads((self.prefix / fixture.RECEIPT).read_text())

    def save(self, receipt: dict) -> None:
        (self.prefix / fixture.RECEIPT).write_text(json.dumps(receipt))

    def complete_delivery(self) -> None:
        receipt = self.receipt()
        immutable = {name: {key: phase[key] for key in ("configured_flags", "cmake_cache_sha256", "products")}
                     for name, phase in receipt["phases"].items()}
        binding = hashlib.sha256(json.dumps([receipt["source"], immutable], sort_keys=True,
                                           separators=(",", ":")).encode()).hexdigest()
        for phase, manifest in (("gil", "ort-provenance.sha256"),
                                ("free-threaded", "ort-provenance-free-threaded.sha256")):
            record = receipt["phases"][phase]
            product = {key: record["products"][-1][key] for key in ("wheel", "member", "sha256")}
            body = f"{product['sha256']}  {product['wheel']}!{product['member']}\n"
            (self.prefix / manifest).write_text(body)
            digest = hashlib.sha256(body.encode()).hexdigest()
            record["wheel_delivery"] = [{"from": product, "to": product,
                "before_manifest_sha256": digest, "after_manifest_sha256": digest,
                "allocated_sha256": "b" * 64, "build_binding_sha256": binding}]
        self.save(receipt)

    def select_phase(self, phase: str) -> None:
        product = self.receipt()["phases"][phase]["products"][-1]
        self.extension = self.extension.with_name(Path(product["member"]).name)
        self.extension.write_bytes(fixture.ELF + phase.encode())
        loader = importlib.machinery.ExtensionFileLoader(self.binding.__name__, str(self.extension))
        self.binding.__file__ = str(self.extension)
        self.binding.__spec__ = importlib.util.spec_from_loader(self.binding.__name__, loader)
        self.ft, self.gil = phase == "free-threaded", phase != "free-threaded"

    def prove(self, phase: str = "gil", prefixes: list[Path] | None = None) -> dict:
        return runtime.prove(prefixes if prefixes is not None else [self.prefix], phase, "v1.31.1")

    def test_enabled_factory_requires_first_success_and_precise_repeat_failure(self) -> None:
        result = self.prove()
        self.assertTrue(result["registered"])
        self.assertEqual(result["sha256"], hashlib.sha256(self.extension.read_bytes()).hexdigest())
        self.assertEqual(result["source"]["revision"], fixture.REVISION)
        self.assertEqual(result["prefix"], str(self.prefix))
        self.assertEqual(result["negative_control"], "missing-registration")
        self.assertEqual(self.binding.unregister_execution_provider_library.call_args_list,
                         [(("WebGpuExecutionProvider",),), (("WebGpuExecutionProvider",),)])

    def test_off_requires_two_precise_absence_verdicts(self) -> None:
        self.built.write_config("OFF")
        self.built.passed(mode="OFF")
        self.built.passed("free-threaded", mode="OFF")
        self.complete_delivery()
        self.binding.unregister_execution_provider_library.side_effect = [OrtFailure(runtime.MISSING), OrtFailure(runtime.MISSING)]
        self.assertFalse(self.prove()["registered"])
        self.assertEqual(self.binding.unregister_execution_provider_library.call_count, 2)

    def test_ft_uses_its_own_extension_and_disabled_gil(self) -> None:
        self.select_phase("free-threaded")
        self.assertEqual(self.prove("free-threaded")["phase"], "free-threaded")

    def test_no_pending_missing_or_broken_delivery_may_run_factories(self) -> None:
        original = self.receipt()
        for kind in ("pending", "no-history", "broken-product", "broken-binding", "broken-manifest-history"):
            with self.subTest(kind=kind):
                receipt = json.loads(json.dumps(original))
                record = receipt["phases"]["gil"]
                if kind == "pending":
                    record["delivery_pending"] = {}
                elif kind == "no-history":
                    del record["wheel_delivery"]
                elif kind == "broken-product":
                    record["wheel_delivery"][0]["from"]["sha256"] = "0" * 64
                elif kind == "broken-binding":
                    record["wheel_delivery"][0]["build_binding_sha256"] = "0" * 64
                else:
                    record["wheel_delivery"].append(json.loads(json.dumps(record["wheel_delivery"][0])))
                    record["wheel_delivery"][1]["before_manifest_sha256"] = "0" * 64
                self.save(receipt)
                with self.assertRaises(ValueError):
                    self.prove()
                self.binding.unregister_execution_provider_library.assert_not_called()

    def test_changed_manifest_or_duplicate_binding_fails_even_with_matching_file_hash(self) -> None:
        manifest = self.prefix / "ort-provenance.sha256"
        original = manifest.read_bytes()
        manifest.write_bytes(original + b"\n")
        with self.assertRaisesRegex(ValueError, "manifest changed"):
            self.prove()
        manifest.write_bytes(original * 2)
        receipt = self.receipt()
        receipt["phases"]["gil"]["wheel_delivery"][-1]["after_manifest_sha256"] = hashlib.sha256(manifest.read_bytes()).hexdigest()
        self.save(receipt)
        with self.assertRaisesRegex(ValueError, "uniquely retain"):
            self.prove()
        self.binding.unregister_execution_provider_library.assert_not_called()

    def test_matching_native_core_does_not_excuse_foreign_or_renamed_python_bytes(self) -> None:
        self.extension.write_bytes(fixture.ELF + b"foreign")
        with self.assertRaisesRegex(ValueError, "matches 0"):
            self.prove()
        self.extension.write_bytes(fixture.ELF + b"gil")
        renamed = self.extension.with_name("foreign.so")
        self.extension.rename(renamed)
        self.binding.__file__ = str(renamed)
        self.binding.__spec__ = importlib.util.spec_from_loader(self.binding.__name__,
            importlib.machinery.ExtensionFileLoader(self.binding.__name__, str(renamed)))
        with self.assertRaisesRegex(ValueError, "member path"):
            self.prove()
        self.binding.unregister_execution_provider_library.assert_not_called()

    def test_nonextension_origin_mismatch_and_nonelf_are_refused(self) -> None:
        original = self.binding.__spec__
        self.binding.__spec__ = None
        with self.assertRaisesRegex(ValueError, "native extension"):
            self.prove()
        self.binding.__spec__ = importlib.util.spec_from_loader(self.binding.__name__,
            importlib.machinery.SourceFileLoader(self.binding.__name__, str(self.extension)))
        with self.assertRaisesRegex(ValueError, "native extension"):
            self.prove()
        assert original is not None
        self.binding.__spec__ = original
        original.origin = str(self.root / "absent")
        with self.assertRaises(OSError):
            self.prove()
        self.select_phase("gil")
        self.extension.write_bytes(b"not ELF")
        with self.assertRaisesRegex(ValueError, "not an ELF"):
            self.prove()

    def test_invalid_flags_and_mismatched_ft_mode_remain_fatal_after_delivery(self) -> None:
        receipt = self.receipt()
        receipt["phases"]["free-threaded"]["configured_flags"] = dict.fromkeys(fixture.FLAGS, "OFF")
        self.save(receipt)
        self.complete_delivery()
        self.select_phase("free-threaded")
        with self.assertRaisesRegex(ValueError, "modes disagree"):
            self.prove("free-threaded")
        receipt = self.receipt()
        receipt["phases"]["gil"]["configured_flags"][fixture.FLAGS[1]] = "OFF"
        self.save(receipt)
        self.complete_delivery()
        with self.assertRaisesRegex(ValueError, "mode binding"):
            self.prove("free-threaded")

    def test_wrong_native_core_or_source_ref_is_fatal(self) -> None:
        self.built.library.write_bytes(fixture.ELF + b"foreign")
        with self.assertRaisesRegex(ValueError, "native core changed"):
            self.prove()
        self.built.library.write_bytes(fixture.ELF + b"native core")
        receipt = self.receipt()
        receipt["source"]["ref"] = "another-ref"
        self.save(receipt)
        with self.assertRaisesRegex(ValueError, "source ref"):
            self.prove()

    def test_interpreter_abi_or_reenabled_gil_cannot_pass(self) -> None:
        with self.assertRaisesRegex(ValueError, "ABI"):
            self.prove("free-threaded")
        self.select_phase("free-threaded")
        self.gil = True
        with self.assertRaisesRegex(ValueError, "GIL enabled"):
            self.prove("free-threaded")
        self.gil = False
        self.binding.unregister_execution_provider_library.side_effect = lambda name: self.toggle_factory(name)
        self.gil_calls = 0
        with self.assertRaisesRegex(ValueError, "GIL enabled"):
            self.prove("free-threaded")

    def toggle_factory(self, name: str) -> None:
        self.assertEqual(name, "WebGpuExecutionProvider")
        self.gil_calls += 1
        self.gil = True
        if self.gil_calls == 2:
            raise OrtFailure(runtime.MISSING)

    def test_native_only_or_missing_ft_phase_cannot_be_a_python_proof(self) -> None:
        self.built.write_config("OFF")
        for wheel in (self.prefix / "wheels").glob("*.whl"):
            wheel.unlink()
        self.built.passed(mode="OFF", without_wheel=True)
        with self.assertRaisesRegex(ValueError, "matches 0"):
            self.prove()
        with self.assertRaisesRegex(ValueError, "matches 0"):
            runtime.owning_receipt([self.prefix], "free-threaded", "v1.31.1", self.extension, "0" * 64)

    def test_unknown_absence_failure_and_unexpected_success_are_fatal(self) -> None:
        for response in (OrtFailure("another failure"), OrtFailure(runtime.MISSING + " unexpected"),
                         RuntimeError(runtime.MISSING), None):
            with self.subTest(response=response):
                self.binding.unregister_execution_provider_library.side_effect = [None, response]
                with self.assertRaises((ValueError, RuntimeError)):
                    self.prove()
        self.binding.unregister_execution_provider_library.side_effect = [OrtFailure(runtime.MISSING)]
        with self.assertRaises(OrtFailure):
            self.prove()

    def test_missing_required_binding_api_is_fatal(self) -> None:
        with (patch.object(self.binding, "unregister_execution_provider_library", None),
              self.assertRaisesRegex(TypeError, "unregistration API")):
            self.prove()
        with (patch.object(self.binding, "Fail", None), self.assertRaisesRegex(TypeError, "Fail exception")):
            self.prove()

    def test_empty_repeated_or_ambiguous_prefixes_fail(self) -> None:
        with self.assertRaisesRegex(ValueError, "distinct"):
            self.prove(prefixes=[])
        with self.assertRaisesRegex(ValueError, "distinct"):
            self.prove(prefixes=[self.prefix, self.prefix / "."])
        with (patch.object(runtime.delivery, "load_receipt", return_value=self.receipt()),
              patch.object(runtime, "completed_product", return_value=self.receipt()["phases"]["gil"]["products"][-1]),
              self.assertRaisesRegex(ValueError, "matches 2")):
            self.prove(prefixes=[self.prefix, self.root / "other"])

    def test_cli_without_an_owning_prefix_cannot_print_success(self) -> None:
        result = subprocess.run([sys.executable, "-I", str(SUBJECT), "--phase", "gil", "--source-ref", "v1.31.1",
                                 "--prefix", str(self.root / "absent")], capture_output=True, text=True, check=False, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("WEBGPU-FACTORY OK:", result.stdout)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)
