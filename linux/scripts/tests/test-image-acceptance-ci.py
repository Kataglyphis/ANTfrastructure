#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Prove native CI binding and failure propagation; no registry, consumer build or physical hardware is exercised."""

import copy
import importlib.util
import json
import subprocess
import tempfile
import unittest
from collections.abc import Callable
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("image_acceptance_ci", ROOT / "linux/scripts/image-acceptance-ci.py")
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Cannot load the native CI proof driver")
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class NativeProofTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.api = module.acceptance_api(ROOT)
        self.plan = self.api["read_plan"](self.api["DEFAULT_PLAN"])
        self.proof: dict[str, Any] = {"schema_version": 1, "hub_revision": "b" * 40,
                      "image": "ghcr.io/owner/image@sha256:" + "a" * 64,
                      "platform": "linux/arm64", "sources": [
            {"name": spec["name"], "repository": spec["repository"], "revision": "c" * 40,
             "submodules": "", "data_locks": {}} for spec in self.plan["consumers"]]}
        self.proof_path = self.root / "proof.json"
        self.write_proof(self.proof)
        self.args = SimpleNamespace(proof=self.proof_path, hub=ROOT, output=self.root / "out", engine="fixture-engine")
        self.head = "b" * 40
        self.dirty = ""
        self.prepared: list[tuple[str, str]] = []
        self.mutate_receipt: Callable[[dict[str, Any]], None] = lambda _value: None
        self.after_check: Callable[[], None] = lambda: None
        self.api["git"] = lambda _root, *argv: self.head if argv == ("rev-parse", "HEAD") else self.dirty
        self.api["source_snapshot"] = self.snapshot
        self.api["check"] = self.check
        self.engine_result = subprocess.CompletedProcess(["fixture-engine"], 0, "", "")
        self.engine_probe = self.enterContext(patch.object(module.subprocess, "run", return_value=self.engine_result))
        self.enterContext(patch.object(module, "acceptance_api", return_value=self.api))
        self.enterContext(patch.object(module.platform, "machine", return_value="aarch64"))

    def write_proof(self, proof: dict[str, Any]) -> None:
        self.proof_path.write_text(json.dumps(proof), encoding="utf-8")

    def snapshot(self, _root: Path, spec: dict[str, Any], expected: dict[str, Any]) -> dict[str, Any]:
        self.prepared.append((spec["name"], expected["revision"]))
        return {key: expected[key] for key in ("repository", "revision", "submodules", "data_locks")}

    def check(self, args: SimpleNamespace) -> None:
        plan = self.api["read_plan"](args.plan)
        work = Path(args.workspace)
        work.mkdir(parents=True)
        rows = []
        for spec, source in zip(plan["consumers"], self.proof["sources"]):
            log = work / (spec["name"] + ".log")
            log.write_text("fixture assertion passed\n", encoding="utf-8")
            rows.append({**source, "command": spec["command"], "exit_code": 0,
                         "log": str(log), "log_sha256": self.api["fingerprint"](log), "resolved_locks": {}})
        receipt = {"schema_version": 1, "image": args.image, "status": "passed",
                   "plan_sha256": self.api["fingerprint"](args.plan), "hub_revision": self.proof["hub_revision"],
                   "platform": plan["platform"], "consumers": rows}
        self.mutate_receipt(receipt)
        Path(args.receipt).write_text(json.dumps(receipt), encoding="utf-8")
        self.after_check()

    def metadata(self) -> dict[str, Any]:
        return json.loads((self.args.output / "native-job.json").read_text(encoding="utf-8"))

    def test_complete_plan_sources_and_raw_receipt_survive(self) -> None:
        module.run_native(self.args)
        selected = self.api["read_plan"](self.args.output / "plan.json")
        self.assertEqual(selected, {**self.plan, "platform": "linux/arm64"})
        self.assertEqual(self.prepared, [(row["name"], row["revision"]) for row in self.proof["sources"]])
        metadata = self.metadata()
        self.assertEqual(metadata["status"], "passed")
        self.assertEqual(len(metadata["source_snapshots"]), len(self.plan["consumers"]))
        self.assertEqual(len(metadata["logs"]), len(self.plan["consumers"]))
        receipt = self.args.output / "receipt.json"
        self.assertEqual(metadata["receipt_sha256"], self.api["fingerprint"](receipt))
        self.assertEqual(metadata["engine_final"]["exit_code"], 0)
        for row in metadata["logs"]:
            self.assertEqual(row["sha256"], self.api["fingerprint"](self.args.output / row["artifact_path"]))

    def test_proof_refuses_mutable_incomplete_or_reordered_inputs_before_work(self) -> None:
        mutants = [lambda p: p.update(schema_version=2), lambda p: p.update(image="ghcr.io/owner/image:latest"),
                   lambda p: p.update(hub_revision="develop"), lambda p: p.update(platform="linux/unknown"),
                   lambda p: p["sources"].pop(), lambda p: p["sources"].reverse(),
                   lambda p: p["sources"][0].update(repository="wrong/repo"),
                   lambda p: p["sources"][0].update(revision="develop"),
                   lambda p: p["sources"][0].update(submodules=None),
                   lambda p: p["sources"][0].update(data_locks=None),
                   lambda p: p.update(timeout_seconds=1), lambda p: p["sources"][0].update(command=["true"])]
        for mutate in mutants:
            value = copy.deepcopy(self.proof)
            mutate(value)
            self.write_proof(value)
            with self.subTest(value=value), self.assertRaises((ValueError, TypeError)):
                module.run_native(self.args)
            self.assertFalse(self.args.output.exists())
        self.engine_probe.assert_not_called()

    def test_planner_cannot_reduce_the_original_timeout(self) -> None:
        original = self.api["materialize_plan"]

        def reduced(source: str, output: str, platform: str) -> None:
            original(source, output, platform)
            path = Path(output)
            value = json.loads(path.read_text())
            value["timeout_seconds"] = 1
            path.write_text(json.dumps(value), encoding="utf-8")

        self.api["materialize_plan"] = reduced
        with self.assertRaisesRegex(ValueError, "every original command and timeout"):
            module.run_native(self.args)
        self.assertEqual(self.prepared, [])
        self.engine_probe.assert_not_called()

    def test_emulated_or_wrong_os_host_refuses_before_allocating_output(self) -> None:
        for system, machine in (("linux", "x86_64"), ("darwin", "aarch64"), ("linux", "unknown")):
            with self.subTest(system=system, machine=machine), patch.object(module.sys, "platform", system), patch.object(module.platform, "machine", return_value=machine):
                with self.assertRaises(ValueError):
                    module.run_native(self.args)
                self.assertFalse(self.args.output.exists())
        self.engine_probe.assert_not_called()

    def test_changed_or_dirty_hub_refuses_before_allocating_output(self) -> None:
        for head, dirty in (("d" * 40, ""), ("b" * 40, " M tracked.py")):
            self.head, self.dirty = head, dirty
            with self.subTest(head=head, dirty=dirty), self.assertRaises(ValueError):
                module.run_native(self.args)
            self.assertFalse(self.args.output.exists())
        self.engine_probe.assert_not_called()

    def test_existing_output_is_preserved(self) -> None:
        self.args.output.mkdir()
        sentinel = self.args.output / "receipt.json"
        sentinel.write_text("original evidence", encoding="utf-8")
        with self.assertRaises(FileExistsError):
            module.run_native(self.args)
        self.assertEqual(sentinel.read_text(), "original evidence")
        self.engine_probe.assert_not_called()

    def test_source_failure_is_fatal_and_writes_failed_metadata(self) -> None:
        self.api["source_snapshot"] = lambda *_args: (_ for _ in ()).throw(ValueError("source pin mismatch"))
        with self.assertRaisesRegex(ValueError, "source pin mismatch"):
            module.run_native(self.args)
        self.assertEqual(self.metadata()["status"], "failed")
        self.assertFalse((self.args.output / "receipt.json").exists())

    def test_zero_check_without_a_receipt_cannot_pass(self) -> None:
        self.api["check"] = lambda _args: None
        with self.assertRaises(FileNotFoundError):
            module.run_native(self.args)
        self.assertEqual(self.metadata()["status"], "failed")

    def test_failed_or_rebound_receipt_is_not_reported_passed(self) -> None:
        mutations = [lambda p: p.update(status="failed"), lambda p: p.update(hub_revision="d" * 40),
                     lambda p: p["consumers"][0].update(revision="e" * 40), lambda p: p["consumers"].pop()]
        for index, mutate in enumerate(mutations):
            self.args.output = self.root / f"bad-receipt-{index}"
            self.mutate_receipt = mutate
            with self.subTest(index=index), self.assertRaises(ValueError):
                module.run_native(self.args)
            self.assertEqual(self.metadata()["status"], "failed")

    def test_hub_modified_by_consumer_cannot_pass(self) -> None:
        self.after_check = lambda: setattr(self, "dirty", " M changed-by-consumer")
        with self.assertRaises(ValueError):
            module.run_native(self.args)
        self.assertEqual(self.metadata()["status"], "failed")

    def test_engine_failure_or_remaining_container_cannot_pass(self) -> None:
        for index, result in enumerate((subprocess.CompletedProcess([], 1, "", "failed query"), subprocess.CompletedProcess([], 0, "leftover\n", ""))):
            self.args.output = self.root / f"engine-{index}"
            self.engine_probe.return_value = result
            with self.subTest(index=index), self.assertRaises(ValueError):
                module.run_native(self.args)
            self.assertEqual(self.metadata()["status"], "failed")
            self.assertEqual(self.metadata()["engine_final"]["exit_code"], result.returncode)

    def test_engine_transport_failure_preserves_failed_metadata(self) -> None:
        self.engine_probe.side_effect = subprocess.TimeoutExpired("fixture-engine", 60)
        with self.assertRaises(ValueError):
            module.run_native(self.args)
        self.assertEqual(self.metadata()["status"], "failed")
        self.assertIn("timed out", self.metadata()["engine_final"]["stderr"])

    def test_describe_refuses_a_moving_hub_before_exporting_it(self) -> None:
        proof = copy.deepcopy(self.proof)
        proof["hub_revision"] = "develop"
        self.write_proof(proof)
        target = self.root / "github-output"
        with self.assertRaises(ValueError):
            module.describe(SimpleNamespace(proof=self.proof_path, github_output=target))
        self.assertFalse(target.exists())

    def test_describe_exports_only_validated_frozen_bindings(self) -> None:
        target = self.root / "github-output"
        module.describe(SimpleNamespace(proof=self.proof_path, github_output=target))
        self.assertEqual(target.read_text().splitlines(), ["image=" + self.proof["image"], "hub_revision=" + self.proof["hub_revision"], "platform=linux/arm64"])
        self.assertFalse(self.args.output.exists())


if __name__ == "__main__":
    unittest.main(buffer=True)
