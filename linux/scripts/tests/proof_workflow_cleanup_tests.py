# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Shared owned-container cleanup fixtures; see docs/local-proof-workflows.md#proof-workflow-fixture-companions."""

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path
from types import ModuleType
from unittest.mock import patch


class OwnedContainerCleanupChecks(unittest.TestCase):
    root: Path
    engine: Path
    trace: Path
    state: Path
    scripts: Path
    container_api: ModuleType

    def setUp(self) -> None:
        super().setUp()
        self.token = "c" * 32
        self.label = "org.kataglyphis.fixture-proof"
        self.state.write_text(f"{self.label}={self.token}")
        self.cidfile = self.root / "container.cid"
        self.cidfile.write_text("a" * 64 + "\n")
        self.owner = self.container_api.OwnedContainers(
            str(self.engine), self.label, self.token
        )

    def test_remove_verifies_absence_and_preserves_foreign_container(self) -> None:
        self.assertEqual(self.owner.cleanup(cidfile=self.cidfile), 0)
        self.assertFalse(self.state.exists())
        calls = [json.loads(line) for line in self.trace.read_text().splitlines()]
        self.assertIn(["inspect", "a" * 64], calls)
        self.assertNotIn(["rm", "--force", "b" * 64], calls)
        self.assertIn(["ps", "-a", "--no-trunc", "--format", "{{.ID}}"], calls)

    def test_successful_remove_that_leaves_container_present_fails(self) -> None:
        with (
            patch.dict(os.environ, {"PROOF_ENGINE_MODE": "remove-lies"}),
            patch.object(self.container_api.time, "sleep"),
        ):
            self.assertNotEqual(self.owner.cleanup(cidfile=self.cidfile), 0)

    def test_late_owned_container_cannot_escape_the_final_inventory_check(self) -> None:
        success = subprocess.CompletedProcess([], 0)
        with (
            patch.object(
                self.container_api.OwnedContainers,
                "ids",
                side_effect=[{"a" * 64}, {"d" * 64}],
            ),
            patch.object(self.container_api.OwnedContainers, "state", return_value={}),
            patch.object(
                self.container_api.OwnedContainers, "settled", return_value=True
            ),
            patch.object(self.container_api.subprocess, "run", return_value=success),
        ):
            self.assertNotEqual(self.owner.cleanup(), 0)

    def test_retain_stops_running_container_without_removing_its_filesystem(
        self,
    ) -> None:
        self.state.with_suffix(".running").touch()
        self.assertEqual(self.owner.cleanup(retain=True, cidfile=self.cidfile), 0)
        self.assertTrue(self.state.exists())
        self.assertFalse(self.state.with_suffix(".running").exists())
        self.assertNotIn('"rm"', self.trace.read_text())

    def test_retain_checks_real_stopped_state_after_success_and_failure(self) -> None:
        for mode, expected in (("stop-lies", 1), ("stop-failure", 17)):
            with (
                self.subTest(mode=mode),
                patch.dict(os.environ, {"PROOF_ENGINE_MODE": mode}),
                patch.object(self.container_api.time, "sleep"),
            ):
                self.state.with_suffix(".running").touch()
                self.assertEqual(
                    self.owner.cleanup(retain=True, cidfile=self.cidfile), expected
                )

    def test_already_stopped_retained_container_needs_no_stop(self) -> None:
        self.assertEqual(self.owner.cleanup(retain=True, cidfile=self.cidfile), 0)
        self.assertNotIn('"stop"', self.trace.read_text())

    def test_changed_ownership_and_malformed_inspection_refuse_mutation(self) -> None:
        for mode in (
            "wrong-label",
            "wrong-id",
            "malformed",
            "missing-state",
            "inspect-failure",
            "list-failure",
        ):
            with (
                self.subTest(mode=mode),
                patch.dict(os.environ, {"PROOF_ENGINE_MODE": mode}),
            ):
                with self.assertRaises((TypeError, ValueError, RuntimeError)):
                    self.owner.cleanup(cidfile=self.cidfile)
                self.assertNotIn('"rm"', self.trace.read_text())
                self.assertNotIn('"stop"', self.trace.read_text())

    def test_foreign_or_invalid_cid_file_refuses_mutation(self) -> None:
        for cid in ("b" * 64, "short", "../foreign"):
            with self.subTest(cid=cid), self.assertRaises(ValueError):
                self.cidfile.write_text(cid)
                self.owner.cleanup(cidfile=self.cidfile)
        self.assertNotIn('"rm"', self.trace.read_text())

    def test_absence_before_container_creation_is_successful_cleanup(self) -> None:
        self.state.unlink()
        self.cidfile.unlink()
        self.assertEqual(self.owner.cleanup(cidfile=self.cidfile), 0)

    def test_invalid_label_or_run_token_is_rejected_before_engine_calls(self) -> None:
        for label, token in (
            ("", self.token),
            ("status=running", self.token),
            (self.label, ""),
            (self.label, "old-run"),
        ):
            with self.subTest(label=label, token=token), self.assertRaises(ValueError):
                self.container_api.OwnedContainers(str(self.engine), label, token)
        self.assertFalse(self.trace.exists())

    def test_retained_state_requires_all_stopped_facts(self) -> None:
        valid = {"Running": False, "Pid": 0, "Status": "exited"}
        self.assertTrue(self.container_api.stopped(valid))
        for broken in (
            {"Running": True},
            {"Pid": 42},
            {"Pid": False},
            {"Status": "running"},
        ):
            with self.subTest(broken=broken):
                self.assertFalse(self.container_api.stopped(valid | broken))
        self.assertFalse(self.container_api.stopped({}))

    def test_cli_preserves_cleanup_status_failure_receipt_and_existing_evidence(
        self,
    ) -> None:
        output = self.root / "cleanup.json"
        command = [
            sys.executable,
            str(self.scripts / "cleanup-owned-containers.py"),
            "--engine",
            str(self.engine),
            "--owner-label",
            self.label,
            "--run-id",
            self.token,
            "--cidfile",
            str(self.cidfile),
            "--output",
            str(output),
        ]
        with patch.dict(os.environ, {"PROOF_ENGINE_MODE": "cleanup-failure"}):
            result = subprocess.run(command, capture_output=True, check=False)
        self.assertEqual(result.returncode, 9, result.stderr)
        record = json.loads(output.read_text())
        self.assertEqual((record["status"], record["exit_status"]), ("failed", 9))
        before, trace = output.read_bytes(), self.trace.read_bytes()
        result = subprocess.run(command, capture_output=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(
            (output.read_bytes(), self.trace.read_bytes()), (before, trace)
        )
