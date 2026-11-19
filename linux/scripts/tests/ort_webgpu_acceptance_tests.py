"""Stub native children and minimal WASM/fake Node cover aggregation, not actual compiled factory registration."""
from __future__ import annotations

import copy
import io
import json
import os
import subprocess
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

import ort_webgpu_media_tests as fixture
from wasm_proof_fixture import create_flavor, install_node_fixture

acceptance = fixture.media.runtime.delivery.source_api("03-media/runtime/ort_webgpu_acceptance.py", ("prove_acceptance", "main"))
wasm = fixture.media.runtime.delivery.source_api("03-media/build/onnxruntime/build/lib/ort-webgpu-wasm-proof.py",
                                               ("checked_receipt", "source_identity", "file_digest"))


class AcceptanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.native = fixture.MediaTests()
        self.native.setUp()
        self.addCleanup(self.native.doCleanups)
        self.args = copy.copy(self.native.args)
        self.args.source_revision = self.native.built.receipt()["source"]["revision"]
        self.args.wasm_config = "Release"
        self.args.wasm_prefix = self.native.root / "WASM products"
        node = install_node_fixture(self.native.root / "node bin")
        self.enterContext(patch.dict(os.environ, {"PATH": str(node) + os.pathsep + os.environ["PATH"]}))
        for flavor in ("asyncify", "jspi"):
            cmake = self.native.root / flavor
            create_flavor(cmake, self.args.wasm_prefix, flavor)
            args = acceptance.wasm_arguments(self.args)
            args.flavor, args.cmake_dir = flavor, cmake
            with redirect_stdout(io.StringIO()):
                wasm.record(args)
        self.runner = self.enterContext(patch.object(acceptance.media, "run_logged", side_effect=self.child))

    def child(self, command: list[str], log: Path, timeout: int) -> str:
        if str(Path(wasm.__file__).resolve()) in command:
            self.native.calls.append(command)
            output = io.StringIO()
            with redirect_stdout(output):
                wasm.replay(acceptance.wasm_arguments(self.args))
            return output.getvalue()
        return self.native.child(command, log, timeout)

    def receipt(self) -> Path:
        return self.args.work_dir / "receipt.json"

    def wasm_receipt(self) -> Path:
        return self.args.wasm_prefix / wasm.RECEIPT

    def test_all_five_factories_share_exact_revision_and_both_flavors(self) -> None:
        result = acceptance.prove_acceptance(self.args)
        self.assertEqual(result["source"], {"ref": "v1.31.1", "revision": self.args.source_revision})
        self.assertEqual([p["phase"] for p in result["native"]["phases"]], ["native", "gil", "free-threaded"])
        self.assertEqual([p["flavor"] for p in result["wasm"]], ["asyncify", "jspi"])
        self.assertEqual(len(result["input_receipts_sha256"]), 4)
        command = self.native.calls[-1]
        self.assertEqual(command[1], "-I")
        for flag, value in [("--flavors", "true"), ("--source-revision", self.args.source_revision),
                            ("--prefix", str(self.args.wasm_prefix)), ("--config", "Release")]:
            self.assertEqual(command[command.index(flag) + 1], value)
        self.assertEqual(json.loads(self.receipt().read_text()), result)

    def test_same_ref_different_revision_fails_before_any_child_or_output(self) -> None:
        receipt = self.native.built.receipt()
        receipt["source"]["revision"] = "2" * 40
        self.native.built.save(receipt)
        self.native.built.complete_delivery()
        with self.assertRaisesRegex(ValueError, "source revisions"):
            acceptance.prove_acceptance(self.args)
        self.runner.assert_not_called()
        self.assertFalse(self.args.work_dir.exists())

    def test_disabled_native_static_plugin_is_not_full_acceptance(self) -> None:
        receipt = self.native.built.receipt()
        for phase in receipt["phases"].values():
            phase["configured_flags"] = dict.fromkeys(phase["configured_flags"], "OFF")
        self.native.built.save(receipt)
        self.native.built.complete_delivery()
        with self.assertRaisesRegex(ValueError, "enabled static WebGPU"):
            acceptance.prove_acceptance(self.args)
        self.runner.assert_not_called()

    def test_pending_free_threaded_delivery_fails_before_any_child(self) -> None:
        receipt = self.native.built.receipt()
        receipt["phases"]["free-threaded"]["delivery_pending"] = {}
        self.native.built.save(receipt)
        with self.assertRaisesRegex(ValueError, "pending"):
            acceptance.prove_acceptance(self.args)
        self.runner.assert_not_called()
        self.assertFalse(self.args.work_dir.exists())

    def test_changed_free_threaded_manifest_fails_before_any_child(self) -> None:
        path = self.args.prefix[0] / "ort-provenance-free-threaded.sha256"
        path.write_bytes(path.read_bytes() + b"changed")
        with self.assertRaisesRegex(ValueError, "manifest changed"):
            acceptance.prove_acceptance(self.args)
        self.runner.assert_not_called()
        self.assertFalse(self.args.work_dir.exists())

    def test_missing_wasm_flavor_fails_before_native_work(self) -> None:
        path = self.wasm_receipt()
        receipt = json.loads(path.read_text())
        del receipt["flavors"]["jspi"]
        path.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError, "both requested flavors"):
            acceptance.prove_acceptance(self.args)
        self.runner.assert_not_called()
        self.assertFalse(self.args.work_dir.exists())

    def test_wrong_wasm_config_or_revision_cannot_be_combined(self) -> None:
        for field, value in [("config", "Debug"), ("source", {"ref": "v1.31.1", "revision": "2" * 40})]:
            path = self.wasm_receipt()
            original = path.read_text()
            changed = json.loads(original)
            changed[field] = value
            path.write_text(json.dumps(changed))
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "source/configuration"):
                acceptance.prove_acceptance(self.args)
            path.write_text(original)
        self.runner.assert_not_called()

    def test_fresh_wasm_replay_requires_two_distinct_valid_rows(self) -> None:
        _, compiled = acceptance.source_bindings(self.args, wasm)
        rows = [json.loads((self.args.wasm_prefix / f"ort-webgpu-wasm.{flavor}.runtime.json").read_text())
                for flavor in ("asyncify", "jspi")]
        for values in [[], rows[:1], [rows[0], rows[0]], list(reversed(rows))]:
            output = "\n".join("WASM-FACTORY-REPLAY: " + json.dumps(r) for r in values)
            with (self.subTest(flavors=[r["flavor"] for r in values]), patch.object(acceptance.media, "run_logged", return_value=output),
                  self.assertRaisesRegex(ValueError, "exactly Asyncify and JSPI")):
                acceptance.replay_wasm(self.args, wasm, compiled)
        rows[1]["returncode"] = 47
        output = "\n".join("WASM-FACTORY-REPLAY: " + json.dumps(r) for r in rows)
        with (patch.object(acceptance.media, "run_logged", return_value=output), self.assertRaisesRegex(ValueError, "failed")):
            acceptance.replay_wasm(self.args, wasm, compiled)

    def test_changed_native_receipt_after_wasm_replay_prevents_overall_receipt(self) -> None:
        def changed(command: list[str], log: Path, timeout: int) -> str:
            output = self.child(command, log, timeout)
            if str(Path(wasm.__file__).resolve()) in command:
                path = self.args.prefix[0] / "ort-webgpu-build.json"
                path.write_bytes(path.read_bytes() + b"\n")
            return output

        self.runner.side_effect = changed
        with self.assertRaisesRegex(ValueError, "changed during acceptance"):
            acceptance.prove_acceptance(self.args)
        self.assertTrue((self.args.work_dir / "native/receipt.json").is_file())
        self.assertFalse(self.receipt().exists())

    def test_raw_wasm_failure_keeps_native_partial_evidence_and_status(self) -> None:
        def failed(command: list[str], log: Path, timeout: int) -> str:
            if str(Path(wasm.__file__).resolve()) in command:
                raise subprocess.CalledProcessError(47, command)
            return self.child(command, log, timeout)

        self.runner.side_effect = failed
        with patch.object(acceptance, "arguments", return_value=self.args), redirect_stdout(io.StringIO()):
            self.assertEqual(acceptance.main(), 47)
        self.assertTrue((self.args.work_dir / "native/receipt.json").is_file())
        self.assertFalse(self.receipt().exists())

    def test_existing_output_is_preserved(self) -> None:
        self.args.work_dir.mkdir()
        self.receipt().write_text("preserve previous evidence")
        with self.assertRaises(FileExistsError):
            acceptance.prove_acceptance(self.args)
        self.assertEqual(self.receipt().read_text(), "preserve previous evidence")
        self.runner.assert_not_called()

    def test_cli_requires_each_exact_source_and_wasm_input(self) -> None:
        argv = ["ort_webgpu_acceptance.py", "--prefix", str(self.args.prefix[0]), "--gil-python", "/gil",
                "--ft-python", "/ft", "--numpy-version", "2.5.4", "--source-ref", "v1.31.1",
                "--work-dir", "/proof", "--source-revision", self.args.source_revision,
                "--wasm-prefix", str(self.args.wasm_prefix), "--wasm-config", "Release"]
        for flag in ("--source-revision", "--wasm-prefix", "--wasm-config"):
            missing = list(argv)
            index = missing.index(flag)
            del missing[index:index + 2]
            stderr = io.StringIO()
            with (self.subTest(flag=flag), patch.object(acceptance.sys, "argv", missing), redirect_stderr(stderr),
                  self.assertRaises(SystemExit) as failure):
                acceptance.arguments()
            self.assertEqual(failure.exception.code, 2)
            self.assertIn(flag, stderr.getvalue())


if __name__ == "__main__":
    import sys
    sys.argv = sys.argv[:1]
    unittest.main()
