"""Mocked command and cleanup controls do not authenticate markers or run a real service or GPU."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("seal_command_unit", SCRIPTS / "seal-command-unit.py")
assert SPEC is not None and SPEC.loader is not None
MAIN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MAIN)


class CommandSealTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="command-seal-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "compiler-cache").mkdir()
        self.unit = "webgpu-command-fixture.service"
        self.invocation = {"unit": self.unit, "run_id": "a" * 32, "owner_label": "org.kataglyphis.fixture"}
        self.terminal = {"Id": self.unit, "LoadState": "loaded", "ActiveState": "active", "SubState": "exited",
                         "MainPID": "0", "ExecMainStatus": "0", "Result": "success", "ExecMainExitTimestampMonotonic": "7"}
        self.stopped = {**self.terminal, "LoadState": "not-found", "ActiveState": "inactive", "SubState": "dead"}
        self.cleanup = {"exit_status": 0, "run_id": "a" * 32, "owner_label": self.invocation["owner_label"]}
        self.args = argparse.Namespace(directory=self.root, unit=self.unit, success_marker=["Actual command passed"])
        (self.root / "invocation.json").write_text(json.dumps(self.invocation))
        (self.root / "unit.log").write_text("Actual command passed\n")
        (self.root / "compiler-cache/exit-status.txt").write_text("command_status=0\ncache_stats_status=0\n")
        (self.root / "compiler-cache/cache-stats.json").write_text(json.dumps({"stats": {"compile_fails": 1}}))

    def stop(self, command: list[str]) -> str:
        self.assertEqual(command, ["systemctl", "--user", "stop", self.unit])
        (self.root / "cleanup.json").write_text(json.dumps(self.cleanup))
        return ""

    def execute(self) -> None:
        with mock.patch.object(MAIN, "unit_state", side_effect=[self.terminal, self.stopped]), \
             mock.patch.object(MAIN, "checked_output", side_effect=self.stop):
            MAIN.run(self.args)

    def refuse_before_stop(self) -> None:
        existed = (self.root / "command-proof-stopped.json").exists()
        with mock.patch.object(MAIN, "unit_state", return_value=self.terminal), \
             mock.patch.object(MAIN, "checked_output") as stop:
            with self.assertRaises((ValueError, OSError, KeyError)):
                MAIN.run(self.args)
            stop.assert_not_called()
        self.assertEqual((self.root / "command-proof-stopped.json").exists(), existed)

    def test_success_records_inputs_and_keeps_cache_failures_visible(self) -> None:
        self.execute()
        result = json.loads((self.root / "command-proof-stopped.json").read_text())
        self.assertEqual(result["status"], "passed-command-unit-lifecycle-only")
        self.assertEqual(result["cache_statistics"]["stats"]["compile_fails"], 1)
        self.assertFalse(result["acceptance_claimed"])
        self.assertEqual(len(result["inputs_sha256"]), 4)
        for name, digest in result["inputs_sha256"].items():
            self.assertEqual(digest, hashlib.sha256(Path(name).read_bytes()).hexdigest())

    def test_existing_exclusive_cleanup_refuses_without_stopping(self) -> None:
        (self.root / "cleanup.json").write_text("preserved runtime cleanup")
        self.refuse_before_stop()

    def test_existing_seals_refuse_without_replacement(self) -> None:
        for name in ["command-proof.json", "command-proof-stopped.json"]:
            with self.subTest(name=name):
                path = self.root / name
                path.write_text("preserved seal")
                self.refuse_before_stop()
                self.assertEqual(path.read_text(), "preserved seal")
                path.unlink()

    def test_wrong_unit_and_run_id_refuse(self) -> None:
        for key, value in [("unit", "other.service"), ("run_id", "truncated")]:
            with self.subTest(key=key):
                (self.root / "invocation.json").write_text(json.dumps({**self.invocation, key: value}))
                self.refuse_before_stop()

    def test_invalid_unit_name_refuses_even_when_metadata_matches(self) -> None:
        self.unit = self.args.unit = "invalid unit.service"
        self.terminal["Id"] = self.unit
        (self.root / "invocation.json").write_text(json.dumps({**self.invocation, "unit": self.unit}))
        self.refuse_before_stop()

    def test_missing_or_inexact_marker_refuses(self) -> None:
        (self.root / "unit.log").write_text("Not Actual command passed yet\n")
        self.refuse_before_stop()
        for markers in [[""], []]:
            self.args.success_marker = markers
            self.refuse_before_stop()

    def test_command_and_statistics_capture_failures_refuse(self) -> None:
        for text in ["command_status=3\ncache_stats_status=0\n", "command_status=0\ncache_stats_status=4\n"]:
            with self.subTest(text=text):
                (self.root / "compiler-cache/exit-status.txt").write_text(text)
                self.refuse_before_stop()

    def test_missing_or_linked_evidence_refuses(self) -> None:
        path = self.root / "compiler-cache/cache-stats.json"
        original = path.read_bytes()
        path.unlink()
        self.refuse_before_stop()
        target = self.root / "actual.json"
        target.write_bytes(original)
        path.symlink_to(target)
        self.refuse_before_stop()

    def test_malformed_statistics_refuse(self) -> None:
        (self.root / "compiler-cache/cache-stats.json").write_text("{}")
        self.refuse_before_stop()

    def test_failed_live_foreign_or_clockless_unit_refuses(self) -> None:
        for key, value in [("MainPID", "42"), ("ExecMainStatus", "1"), ("Id", "foreign.service"),
                           ("ExecMainExitTimestampMonotonic", "0")]:
            with self.subTest(key=key):
                original = self.terminal
                self.terminal = {**original, key: value}
                self.refuse_before_stop()
                self.terminal = original

    def test_failed_or_foreign_cleanup_cannot_produce_stopped_seal(self) -> None:
        for key, value in [("exit_status", 9), ("run_id", "b" * 32), ("owner_label", "foreign.owner")]:
            with self.subTest(key=key):
                self.cleanup = {"exit_status": 0, "run_id": "a" * 32, "owner_label": self.invocation["owner_label"], key: value}
                with self.assertRaises(ValueError):
                    self.execute()
                self.assertFalse((self.root / "command-proof-stopped.json").exists())
                (self.root / "command-proof.json").unlink()
                (self.root / "cleanup.json").unlink()

    def test_unit_still_running_after_stop_refuses(self) -> None:
        self.stopped["MainPID"] = "42"
        with self.assertRaises(ValueError):
            self.execute()
        self.assertFalse((self.root / "command-proof-stopped.json").exists())


if __name__ == "__main__":
    unittest.main()
