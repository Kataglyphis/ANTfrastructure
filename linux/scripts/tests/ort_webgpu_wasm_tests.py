"""Synthetic CMake/module/cache fixtures test provenance refusal, not compilation, factories or JS loaders."""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import tempfile
import unittest
from pathlib import Path
from types import ModuleType
from typing import cast
from unittest.mock import Mock, patch

from wasm_proof_fixture import create_flavor, expected_flags, install_node_fixture

g = cast(ModuleType, globals()["g"])


class WasmProofTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        node_fixture = install_node_fixture(self.root / "bin")
        self.enterContext(patch.dict(os.environ, {"PATH": str(node_fixture) + os.pathsep + os.environ["PATH"]}))
        self.prefix = self.root / "artifacts"
        self.prefix.mkdir()
        self.args = argparse.Namespace(action="record", prefix=self.prefix, config="Release", source_ref="v1.31.1",
            source_revision="1" * 40, flavors="true", flavor="asyncify", cmake_dir=self.root / "asyncify", destination=None)
        for flavor in ("asyncify", "jspi"):
            create_flavor(self.root / flavor, self.prefix, flavor)

    def record(self, flavor: str) -> None:
        self.args.flavor = flavor
        self.args.cmake_dir = self.root / flavor
        g.record(self.args)

    def both(self) -> None:
        for flavor in ("asyncify", "jspi"):
            self.record(flavor)

    def test_both_flavors_bind_six_typed_flags_source_configuration_and_bytes(self) -> None:
        self.both()
        g.verify(self.args)
        receipt = json.loads((self.prefix / g.RECEIPT).read_text())
        self.assertEqual(set(receipt["flavors"]), {"asyncify", "jspi"})
        for flavor, phase in receipt["flavors"].items():
            self.assertEqual(len(phase["configured_flags"]), 6)
            self.assertEqual(phase["configured_flags"], expected_flags(flavor))
            self.assertEqual(phase["configured_flags"]["onnxruntime_ENABLE_WEBASSEMBLY_JSPI"], "ON" if flavor == "jspi" else "OFF")
            self.assertEqual(len(phase["cmake_cache_sha256"]), 64)
            self.assertEqual(phase["product"]["path"], f"ort-wasm-simd-threaded.{flavor}.wasm")

    def test_raw_failed_factory_record_is_preserved_without_accepting_the_flavor(self) -> None:
        node = self.root / "bin/node"
        node.write_text("#!/usr/bin/env python3\nprint('raw failing fixture')\nraise SystemExit(47)\n")
        with self.assertRaisesRegex(ValueError, "failed"):
            self.record("asyncify")
        raw = json.loads((self.prefix / "ort-webgpu-wasm.asyncify.runtime.json").read_text())
        self.assertEqual(raw["returncode"], 47)
        self.assertIn("raw failing fixture", raw["stdout"])
        self.assertFalse((self.prefix / g.RECEIPT).exists())

    def test_runtime_receipt_bytes_and_self_consistent_failed_verdicts_are_rejected(self) -> None:
        self.both()
        runtime = self.prefix / "ort-webgpu-wasm.jspi.runtime.json"
        original = runtime.read_bytes()
        runtime.write_bytes(original + b" ")
        with self.assertRaisesRegex(ValueError, "runtime receipt changed"):
            g.verify(self.args)
        changed = json.loads(original)
        changed["returncode"] = 47
        runtime.write_text(json.dumps(changed))
        path = self.prefix / g.RECEIPT
        receipt = json.loads(path.read_text())
        receipt["flavors"]["jspi"]["runtime"]["sha256"] = hashlib.sha256(runtime.read_bytes()).hexdigest()
        path.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError, "failed"):
            g.verify(self.args)

    def test_fresh_replay_runs_exactly_both_flavors_without_rewriting_receipts(self) -> None:
        self.both()
        before = {path.name: path.read_bytes() for path in self.prefix.iterdir()}
        with patch.dict(g.RUNTIME, {"run_probe": Mock(wraps=g.RUNTIME["run_probe"])}):
            g.replay(self.args)
            self.assertEqual([call.args[1] for call in g.RUNTIME["run_probe"].call_args_list], ["asyncify", "jspi"])
        self.assertEqual({path.name: path.read_bytes() for path in self.prefix.iterdir()}, before)

    def test_compiled_probe_carries_the_hubs_exact_original_mit_notice(self) -> None:
        hub = Path(__file__).resolve().parents[3]
        original = hub / "linux/scripts/03-media/build/onnxruntime/build/lib/webgpu-factory-probe/LICENSE"
        self.assertEqual(original.read_bytes(), (hub / "LICENSE").read_bytes())
        self.both()
        self.assertEqual((self.prefix / g.PROBE_LICENSE).read_bytes(), original.read_bytes())
        receipt = json.loads((self.prefix / g.RECEIPT).read_text())
        for phase in receipt["flavors"].values():
            self.assertEqual(phase["product"]["probe_license"]["sha256"], hashlib.sha256(original.read_bytes()).hexdigest())

    def test_changed_missing_or_linked_mit_notice_cannot_be_accepted_or_overwritten(self) -> None:
        self.both()
        notice = self.prefix / g.PROBE_LICENSE
        notice.write_text("foreign nonempty license")
        with self.assertRaises(ValueError):
            g.verify(self.args)
        with self.assertRaises(ValueError):
            g.stage_probe_license(self.prefix)
        self.assertEqual(notice.read_text(), "foreign nonempty license")
        notice.unlink()
        with self.assertRaises(ValueError):
            g.verify(self.args)
        outside = self.root / "outside license"
        outside.write_text("preserved")
        notice.symlink_to(outside)
        with self.assertRaises(ValueError):
            g.stage_probe_license(self.prefix)
        self.assertEqual(outside.read_text(), "preserved")
        notice.unlink()
        absent = self.root / "absent license target"
        notice.symlink_to(absent)
        with self.assertRaises(ValueError):
            g.stage_probe_license(self.prefix)
        self.assertFalse(absent.exists())

    def test_one_flavor_is_not_a_complete_bundle(self) -> None:
        self.record("asyncify")
        with self.assertRaisesRegex(ValueError, "both"):
            g.verify(self.args)
        with self.assertRaisesRegex(ValueError, "both"):
            g.seal_cache(self.args)
        self.assertFalse((self.prefix / ".complete").exists())

    def test_duplicate_phase_or_changed_first_product_cannot_replace_receipt(self) -> None:
        self.record("asyncify")
        before = (self.prefix / g.RECEIPT).read_bytes()
        with self.assertRaisesRegex(ValueError, "already recorded"):
            self.record("asyncify")
        (self.prefix / "ort-wasm-simd-threaded.asyncify.wasm").write_bytes(b"\0asm\x01\0\0\0changed")
        with self.assertRaisesRegex(ValueError, "changed after"):
            self.record("jspi")
        self.assertEqual((self.prefix / g.RECEIPT).read_bytes(), before)

    def test_each_mode_flag_must_be_unique_typed_and_match_the_actual_flavor(self) -> None:
        cache = self.args.cmake_dir / "CMakeCache.txt"
        original = cache.read_text()
        for name, expected in expected_flags("asyncify").items():
            for replacement in ("", f"{name}:STRING={expected}\n", f"{name}:BOOL={'OFF' if expected == 'ON' else 'ON'}\n",
                                f"{name}:BOOL={expected}\n{name}:BOOL={expected}\n"):
                cache.write_text(original.replace(f"{name}:BOOL={expected}\n", replacement))
                with self.subTest(flag=name, replacement=replacement), self.assertRaises(ValueError):
                    self.record("asyncify")
        cache.write_text(original)

    def test_build_configuration_is_checked_against_cmake(self) -> None:
        self.args.config = "Debug"
        with self.assertRaisesRegex(ValueError, "CMAKE_BUILD_TYPE"):
            self.record("asyncify")

    def test_non_wasm_missing_empty_or_linked_products_and_loaders_refuse(self) -> None:
        wasm = self.prefix / "ort-wasm-simd-threaded.asyncify.wasm"
        for value in (b"", b"ELF", b"\0asm\x02\0\0\0"):
            wasm.write_bytes(value)
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.record("asyncify")
        wasm.write_bytes(b"\0asm\x01\0\0\0")
        loader = self.prefix / "ort-wasm-simd-threaded.asyncify.mjs"
        loader.write_text("")
        with self.assertRaises(ValueError):
            self.record("asyncify")
        loader.unlink()
        loader.symlink_to(self.root / "missing")
        with self.assertRaises(ValueError):
            self.record("asyncify")

    def test_source_config_or_claimed_flags_cannot_drift_after_recording(self) -> None:
        self.both()
        path = self.prefix / g.RECEIPT
        original = json.loads(path.read_text())
        for field, value in (("source", {"ref": "foreign", "revision": "1" * 40}), ("config", "Debug"), ("schema_version", 1)):
            changed = copy.deepcopy(original)
            changed[field] = value
            path.write_text(json.dumps(changed))
            with self.subTest(field=field), self.assertRaises(ValueError):
                g.verify(self.args)
        changed = copy.deepcopy(original)
        changed["flavors"]["jspi"]["configured_flags"]["onnxruntime_USE_EP_API_ADAPTERS"] = "OFF"
        path.write_text(json.dumps(changed))
        with self.assertRaisesRegex(ValueError, "legacy"):
            g.verify(self.args)
        changed = copy.deepcopy(original)
        changed["flavors"]["jspi"]["cmake_cache_sha256"] = "invalid"
        path.write_text(json.dumps(changed))
        with self.assertRaisesRegex(ValueError, "cache identity"):
            g.verify(self.args)

    def test_disabled_flavors_refuse_leftover_plugin_payload(self) -> None:
        self.args.flavors = "false"
        with self.assertRaisesRegex(ValueError, "disabled"):
            g.verify(self.args)
        for p in self.prefix.iterdir():
            p.unlink()
        with self.assertRaisesRegex(ValueError, "no WASM"):
            g.verify(self.args)
        (self.prefix / "ort-wasm-simd-threaded.wasm").write_bytes(b"\0asm\x01\0\0\0")
        g.verify(self.args)

    def test_cache_marker_source_modes_and_every_payload_are_bound(self) -> None:
        self.both()
        g.seal_cache(self.args)
        g.verify_cache(self.args)
        marker = (self.prefix / ".complete").read_bytes()
        (self.prefix / ".complete").write_text("")
        with self.assertRaises(ValueError):
            g.verify_cache(self.args)
        (self.prefix / ".complete").write_bytes(marker)
        (self.prefix / ".complete").write_text(json.dumps({"cache_sha256": "0" * 64}))
        with self.assertRaisesRegex(ValueError, "marker differs"):
            g.verify_cache(self.args)
        (self.prefix / ".complete").write_bytes(marker)
        for name, value in (("config", "Debug"), ("source_ref", "other"), ("source_revision", "2" * 40), ("flavors", "false")):
            with self.subTest(field=name), patch.object(self.args, name, value), self.assertRaises(ValueError):
                g.verify_cache(self.args)
        (self.prefix / "unrecorded").write_text("extra")
        with self.assertRaises(ValueError):
            g.verify_cache(self.args)

    def test_loader_changes_invalidate_the_cache_but_are_not_a_wasm_code_claim(self) -> None:
        self.both()
        g.seal_cache(self.args)
        (self.prefix / "ort-wasm-simd-threaded.jspi.mjs").write_text("different loader")
        with self.assertRaisesRegex(ValueError, "shared-cache"):
            g.verify_cache(self.args)
        with self.assertRaisesRegex(ValueError, "changed after"):
            g.verify(self.args)

    def test_recipe_changes_and_invalid_cli_source_cannot_reuse_or_reset(self) -> None:
        self.both()
        g.seal_cache(self.args)
        with patch.object(g, "recipe_fingerprint", return_value={"changed recipe": "0" * 64}), self.assertRaises(ValueError):
            g.verify_cache(self.args)
        self.assertEqual(len(g.recipe_fingerprint()), 11)
        keep = self.prefix / "keep"
        keep.write_text("preserved")
        self.args.action = "reset"
        self.args.source_revision = "invalid"
        with patch.object(g, "arguments", return_value=self.args):
            self.assertEqual(g.main(), 1)
        self.assertEqual(keep.read_text(), "preserved")

    def test_disabled_cache_still_requires_the_matching_source_and_configuration(self) -> None:
        g.reset(self.args)
        self.args.flavors = "false"
        (self.prefix / "core.wasm").write_bytes(b"\0asm\x01\0\0\0")
        g.seal_cache(self.args)
        for field, value in (("source_ref", "other"), ("config", "Debug")):
            with patch.object(self.args, field, value), self.assertRaisesRegex(ValueError, "shared-cache"):
                g.verify_cache(self.args)

    def test_copy_checks_bytes_and_does_not_deliver_cache_internal_markers(self) -> None:
        self.both()
        g.seal_cache(self.args)
        destination = self.root / "delivered"
        destination.mkdir()
        (destination / "stale").write_text("old")
        self.args.destination = destination
        g.copy_cache(self.args)
        self.assertFalse((destination / "stale").exists())
        self.assertFalse((destination / ".complete").exists())
        self.assertFalse((destination / g.CACHE).exists())
        delivered = copy.copy(self.args)
        delivered.prefix = destination
        g.verify(delivered)

    def test_overlapping_or_failed_copy_never_publishes_success(self) -> None:
        self.both()
        g.seal_cache(self.args)
        for destination in (self.prefix, self.root):
            self.args.destination = destination
            with self.subTest(destination=destination), self.assertRaisesRegex(ValueError, "overlap"):
                g.copy_cache(self.args)
        self.args.destination = self.root / "failed copy"
        self.args.destination.mkdir()
        with patch.object(g.shutil, "copy2", side_effect=OSError("copy failed")), self.assertRaises(OSError):
            g.copy_cache(self.args)
        self.assertFalse((self.args.destination / g.RECEIPT).exists())

    def test_copied_loader_bytes_must_match_even_though_the_wasm_receipt_is_unchanged(self) -> None:
        self.both()
        g.seal_cache(self.args)
        self.args.destination = self.root / "changed copy"
        self.args.destination.mkdir()
        real_copy = g.shutil.copy2
        def changed(source: Path, target: Path) -> None:
            real_copy(source, target)
            if target.suffix == ".mjs":
                target.write_text("changed nonempty loader")
        with patch.object(g.shutil, "copy2", side_effect=changed), self.assertRaisesRegex(ValueError, "copy changed"):
            g.copy_cache(self.args)

    def test_nonregular_prefix_or_reset_entries_refuse_before_deleting(self) -> None:
        keep = self.prefix / "keep"
        keep.write_text("preserved")
        (self.prefix / "unexpected directory").mkdir()
        with self.assertRaises(ValueError):
            g.reset(self.args)
        self.assertEqual(keep.read_text(), "preserved")
        alias = self.root / "alias"
        alias.symlink_to(self.prefix, target_is_directory=True)
        with patch.object(self.args, "prefix", alias), self.assertRaises(ValueError):
            g.reset(self.args)

    def test_receipt_links_and_invalid_revision_are_not_proof(self) -> None:
        self.both()
        alias = self.root / "linked prefix"
        alias.symlink_to(self.prefix, target_is_directory=True)
        with patch.object(self.args, "prefix", alias), self.assertRaises(ValueError):
            g.verify(self.args)
        receipt = self.prefix / g.RECEIPT
        outside = self.root / "outside.json"
        receipt.rename(outside)
        receipt.symlink_to(outside)
        with self.assertRaises(ValueError):
            g.verify(self.args)
        self.args.source_revision = "not a revision"
        with self.assertRaises(ValueError):
            g.source_identity(self.args)

    def test_a_self_consistent_cache_still_requires_valid_flavor_semantics(self) -> None:
        self.both()
        g.seal_cache(self.args)
        path = self.prefix / g.RECEIPT
        receipt = json.loads(path.read_text())
        receipt["flavors"]["jspi"]["configured_flags"]["onnxruntime_WEBGPU_STATIC_PLUGIN"] = "OFF"
        path.write_text(json.dumps(receipt))
        manifest_path = self.prefix / g.CACHE
        manifest = json.loads(manifest_path.read_text())
        manifest["files"][g.RECEIPT] = hashlib.sha256(path.read_bytes()).hexdigest()
        manifest_path.write_text(json.dumps(manifest))
        (self.prefix / ".complete").write_text(json.dumps({"cache_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest()}))
        with self.assertRaisesRegex(ValueError, "legacy"):
            g.verify_cache(self.args)


if __name__ == "__main__":
    unittest.main(argv=[__file__])
