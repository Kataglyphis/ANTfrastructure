#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Prove failed or incomplete consumer receipts cannot promote an image."""
import copy
import hashlib
import importlib.util
import json
import subprocess
import tempfile
import types
import unittest
import urllib.error
from collections.abc import Sequence
from email.message import Message
from pathlib import Path
from typing import IO, Any, Literal, TypedDict, Unpack
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "image-acceptance.py"
SPEC = importlib.util.spec_from_file_location("image_acceptance", SOURCE)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Cannot load the image acceptance fixture")
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)
INDEX_MEDIA = "application/vnd.oci.image.index.v1+json"
MANIFEST_MEDIA = "application/vnd.oci.image.manifest.v1+json"


class RunOptions(TypedDict, total=False):
    text: Literal[True]
    capture_output: bool
    check: bool
    timeout: float | None
    stdout: IO[bytes] | int | None
    stderr: IO[bytes] | int | None


def index_bytes(platforms: Sequence[str], *, attestations: bool = False) -> bytes:
    entries: list[dict[str, object]] = []
    for name in platforms:
        parts = name.split("/")
        platform = dict(zip(("os", "architecture", "variant"), parts))
        digest = "sha256:" + hashlib.sha256(name.encode()).hexdigest()
        entries.append({"mediaType": MANIFEST_MEDIA, "digest": digest, "size": 512, "platform": platform})
        if attestations:
            entries.append({"mediaType": MANIFEST_MEDIA, "digest": "sha256:" + hashlib.sha256((name + "-attestation").encode()).hexdigest(),
                            "size": 256, "platform": {"os": "unknown", "architecture": "unknown"},
                            "annotations": {"vnd.docker.reference.type": "attestation-manifest", "vnd.docker.reference.digest": digest}})
    return json.dumps({"schemaVersion": 2, "mediaType": INDEX_MEDIA, "manifests": entries}, indent=2).encode()


INDEX = index_bytes(("linux/amd64", "linux/arm64", "linux/riscv64"), attestations=True)
IMAGE = "ghcr.io/kataglyphis/test@sha256:" + hashlib.sha256(INDEX).hexdigest()


class ReceiptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.plan = Path(self.directory.name) / "plan.json"
        self.plan.write_text(json.dumps({"schema_version": 1, "platform": "linux/amd64",
                                        "timeout_seconds": 30, "consumers": [
            {"name": "first", "repository": "owner/first", "ref": "develop", "command": ["true"]},
            {"name": "second", "repository": "owner/second", "ref": "develop", "command": ["true"]}]}), encoding="utf-8")
        self.receipt = {"schema_version": 1, "image": IMAGE, "status": "passed",
                        "plan_sha256": module.fingerprint(self.plan), "hub_revision": "b" * 40,
                        "platform": "linux/amd64", "consumers": [
            {"name": name, "repository": "owner/" + name, "revision": "c" * 40,
             "command": ["true"], "exit_code": 0, "log_sha256": "d" * 64,
             "submodules": "", "data_locks": {}, "resolved_locks": {}} for name in ("first", "second")]}

    def test_complete_receipt_passes(self) -> None:
        self.assertIs(module.validate_receipt(self.receipt, IMAGE, self.plan), self.receipt)

    def test_failure_skip_missing_and_wrong_source_fail(self) -> None:
        for change in (lambda r: r.update(status="failed"),
                       lambda r: r["consumers"].pop(),
                       lambda r: r["consumers"][0].update(exit_code=None),
                       lambda r: r["consumers"][0].update(exit_code=1),
                       lambda r: r["consumers"][0].update(command=["false"]),
                       lambda r: r["consumers"][0].update(revision="develop"),
                       lambda r: r["consumers"][0].update(repository="other/first"),
                       lambda r: r["consumers"][0].pop("log_sha256"),
                       lambda r: r["consumers"][0].pop("resolved_locks")):
            value = copy.deepcopy(self.receipt)
            change(value)
            with self.assertRaises(ValueError):
                module.validate_receipt(value, IMAGE, self.plan)

    def test_wrong_image_or_changed_plan_fails(self) -> None:
        with self.assertRaises(ValueError):
            module.validate_receipt(self.receipt, IMAGE.replace("a", "d"), self.plan)
        self.plan.write_text(self.plan.read_text() + "\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "exact plan"):
            module.validate_receipt(self.receipt, IMAGE, self.plan)

    def test_mutable_input_and_empty_plan_fail(self) -> None:
        with self.assertRaises(ValueError):
            module.image_parts("ghcr.io/kataglyphis/test:latest")
        self.plan.write_text('{"schema_version":1,"consumers":[]}', encoding="utf-8")
        with self.assertRaises(ValueError):
            module.read_plan(self.plan)

    def test_no_registry_write_when_receipt_failed(self) -> None:
        self.receipt["status"] = "failed"
        path = Path(self.directory.name) / "receipt.json"
        path.write_text(json.dumps(self.receipt), encoding="utf-8")
        with patch.object(module, "Registry") as registry, self.assertRaises(ValueError):
            module.promote(types.SimpleNamespace(receipt=path, plan=self.plan, target="ghcr.io/kataglyphis/test:latest"))
        registry.assert_not_called()

    def promote_index(
        self, candidate: bytes = INDEX, current: bytes = INDEX, *, error: Exception | None = None
    ) -> None:
        if isinstance(error, urllib.error.HTTPError):
            self.addCleanup(error.close)
        path = Path(self.directory.name) / "receipt.json"
        image = "ghcr.io/kataglyphis/test@sha256:" + hashlib.sha256(candidate).hexdigest()
        receipt = dict(self.receipt, image=image)
        path.write_text(json.dumps(receipt), encoding="utf-8")
        tested = (candidate, INDEX_MEDIA, image.split("@", 1)[1])
        target = error or (current, INDEX_MEDIA, "sha256:" + hashlib.sha256(current).hexdigest())
        with patch.object(module, "Registry") as registry:
            registry.return_value.manifest.side_effect = [tested, target, tested]
            try:
                module.promote(types.SimpleNamespace(receipt=path, plan=self.plan, target="ghcr.io/kataglyphis/test:latest"))
            except (ValueError, OSError):
                registry.return_value.publish.assert_not_called()
                raise
            registry.return_value.publish.assert_called_once_with("latest", candidate, INDEX_MEDIA)
            self.assertEqual(registry.return_value.manifest.call_args_list[-1].args, ("latest",))

    def test_promote_reuses_the_exact_tested_index_bytes(self) -> None:
        self.promote_index()

    def test_promote_rejects_lost_or_untested_platforms_and_duplicates(self) -> None:
        for candidate, message in ((index_bytes(("linux/amd64",)), "remove published"),
                                   (index_bytes(("linux/arm64",)), "tested platform"),
                                   (index_bytes(("linux/amd64", "linux/amd64")), "repeats")):
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                self.promote_index(candidate)

    def test_promote_allows_only_clear_404_when_creating_a_tag(self) -> None:
        self.promote_index(error=urllib.error.HTTPError("https://ghcr.io/tag", 404, "missing", Message(), None))
        for code in (401, 403, 429, 500):
            with self.subTest(code=code), self.assertRaises(urllib.error.HTTPError):
                self.promote_index(error=urllib.error.HTTPError("https://ghcr.io/tag", code, "failed", Message(), None))
        with self.assertRaises(urllib.error.URLError):
            self.promote_index(error=urllib.error.URLError("network unavailable"))

    def test_index_rejects_unknown_entries_without_a_bound_attestation(self) -> None:
        for change in (lambda entry: entry.pop("annotations"),
                       lambda entry: entry["annotations"].update({"vnd.docker.reference.digest": "sha256:" + "f" * 64}),
                       lambda entry: entry.update(digest="sha256:child"),
                       lambda entry: entry.update(size=0),
                       lambda entry: entry.update(mediaType="application/octet-stream")):
            index = json.loads(INDEX)
            change(index["manifests"][1])
            with self.assertRaises(ValueError):
                module.runtime_platforms(json.dumps(index).encode(), INDEX_MEDIA)

    def test_tested_platform_matches_an_explicit_architecture_variant(self) -> None:
        self.promote_index(index_bytes(("linux/amd64/v3",)), index_bytes(("linux/amd64/v3",)))

    def test_replay_restores_locks_and_rejects_changes_or_escapes(self) -> None:
        root = Path(self.directory.name)
        content = "exact resolved versions\n"
        locks = {"nested/pubspec.lock": {"content": content, "sha256": hashlib.sha256(content.encode()).hexdigest()}}
        module.restore_locks(root, locks)
        self.assertEqual((root / "nested/pubspec.lock").read_text(), content)
        (root / "nested/pubspec.lock").write_text("different")
        with self.assertRaisesRegex(ValueError, "differs"):
            module.restore_locks(root, locks)
        for path in ("../pubspec.lock", "/pubspec.lock", "C:/pubspec.lock", "nested/evil.py", "nested\\pubspec.lock"):
            with self.assertRaises(ValueError):
                module.restore_locks(root, {path: locks["nested/pubspec.lock"]})
        locks["nested/pubspec.lock"]["content"] += "tamper"
        with self.assertRaisesRegex(ValueError, "hash"):
            module.restore_locks(root, locks)

    def test_collected_crlf_lock_round_trips_without_changing_its_hash(self) -> None:
        root = Path(self.directory.name) / "checkout"
        root.mkdir()
        data = b'version = 4\r\n\r\n[[package]]\r\nname = "example"\r\n'
        (root / "Cargo.lock").write_bytes(data)
        with patch.object(module, "git", return_value="Cargo.toml"):
            locks = module.collect_locks(root)
        self.assertIn("\r\n", locks["Cargo.lock"]["content"])
        restored = Path(self.directory.name) / "restored"
        restored.mkdir()
        module.restore_locks(restored, locks)
        self.assertEqual((restored / "Cargo.lock").read_bytes(), data)

    def run_check(
        self, exit_code: int = 0, timeout: bool = False, dirty_after: bool = False,
        cleanup_error: bool = False,
    ) -> tuple[dict[str, Any], list[Any]]:
        root = Path(self.directory.name)
        args = types.SimpleNamespace(image=IMAGE, plan=self.plan, workspace=root / "sources",
                                     receipt=root / "result.json", engine="engine", replay=None)
        snapshot = {"repository": "owner/first", "revision": "c" * 40, "submodules": "", "data_locks": {}}
        cleanup_failed = False
        def fake_run(command: Sequence[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
            nonlocal cleanup_failed
            if command[1] == "run":
                if timeout:
                    raise subprocess.TimeoutExpired(command, 30)
                return subprocess.CompletedProcess(command, exit_code)
            if command[1] == "rm" and cleanup_error and not cleanup_failed:
                cleanup_failed = True
                raise subprocess.TimeoutExpired(command, 60)
            return subprocess.CompletedProcess(command, 0, stdout="", stderr="")
        def fake_snapshot(checkout: Path, spec: dict[str, Any], expected: object) -> dict[str, object]:
            checkout.mkdir(parents=True, exist_ok=True)
            return dict(snapshot, repository=spec["repository"])
        def fake_git(checkout: Path, *command: str) -> str:
            if command[0] == "status":
                return " M Cargo.lock" if dirty_after and Path(checkout) != module.ROOT else ""
            return "b" * 40
        with patch.object(module, "git", side_effect=fake_git), \
             patch.object(module, "source_snapshot", side_effect=fake_snapshot), \
             patch.object(module, "collect_locks", return_value={}), \
             patch.object(module.subprocess, "run", side_effect=fake_run) as run:
            if exit_code or timeout or dirty_after or cleanup_error:
                with self.assertRaises(ValueError):
                    module.check(args)
            else:
                module.check(args)
        return json.loads(args.receipt.read_text()), run.call_args_list

    def test_successful_command_that_changes_tracked_sources_keeps_failed_receipt(self) -> None:
        receipt, _ = self.run_check(dirty_after=True)
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(len(receipt["consumers"]), 1)
        self.assertEqual(receipt["consumers"][0]["exit_code"], 0)
        self.assertEqual(receipt["consumers"][0]["source_changes"], " M Cargo.lock")
        self.assertIn("modified tracked acceptance sources", receipt["error"])
        self.assertIn("log_sha256", receipt["consumers"][0])

    def test_real_git_freezes_tracked_locks_and_permits_new_ignored_locks(self) -> None:
        original_run = subprocess.run
        for tracked in (True, False):
            with self.subTest(tracked=tracked):
                work = Path(self.directory.name) / str(tracked)
                checkout = work / "first"
                checkout.mkdir(parents=True)
                module.git(checkout, "init", "--quiet")
                (checkout / "Cargo.toml").write_text("[workspace]\n", encoding="utf-8")
                (checkout / ".gitignore").write_text("" if tracked else "Cargo.lock\n", encoding="utf-8")
                if tracked:
                    (checkout / "Cargo.lock").write_text("before\n", encoding="utf-8")
                module.git(checkout, "add", ".")
                module.git(checkout, "-c", "user.name=Acceptance test", "-c", "user.email=acceptance@example.invalid",
                           "commit", "--quiet", "-m", "fixture")
                def fake_engine(
                    command: Sequence[str], checkout: Path = checkout, **kwargs: Unpack[RunOptions]
                ) -> subprocess.CompletedProcess[str] | subprocess.CompletedProcess[bytes]:
                    if command[0] != "engine":
                        return original_run(command, **kwargs)
                    if command[1] == "run":
                        (checkout / "Cargo.lock").write_bytes(b"after\n")
                    return subprocess.CompletedProcess(command, 0)
                spec = {"name": "first", "repository": "owner/first", "ref": "develop", "command": ["true"]}
                args = types.SimpleNamespace(engine="engine", image=IMAGE)
                plan = {"platform": "linux/amd64", "timeout_seconds": 30}
                row = {}
                with patch.object(module.subprocess, "run", side_effect=fake_engine):
                    if tracked:
                        with self.assertRaisesRegex(ValueError, "modified tracked"):
                            module.run_consumer(args, plan, work, 0, spec, row, None, False)
                        self.assertIn("Cargo.lock", row["source_changes"])
                    else:
                        module.run_consumer(args, plan, work, 0, spec, row, None, False)
                self.assertEqual(row["exit_code"], 0)
                self.assertEqual(row["resolved_locks"]["Cargo.lock"]["content"], "after\n")

    def test_check_runs_every_consumer_with_the_immutable_digest(self) -> None:
        receipt, calls = self.run_check()
        module.validate_receipt(receipt, IMAGE, self.plan)
        runs = [call.args[0] for call in calls if call.args[0][1] == "run" and "chown" not in call.args[0]]
        self.assertEqual(len(runs), 2)
        self.assertTrue(all(IMAGE in command and "never" in command for command in runs))

    def test_linux_bind_owner_is_restored_after_success_failure_and_timeout(self) -> None:
        for code, timeout in ((0, False), (1, False), (0, True)):
            with self.subTest(code=code, timeout=timeout), patch.object(module.sys, "platform", "linux"):
                receipt, calls = self.run_check(code, timeout)
                commands = [call.args[0] for call in calls]
                runs = [command for command in commands if command[1] == "run" and "chown" not in command]
                cleanup = [command for command in commands if command[1] == "run" and "chown" in command]
                self.assertEqual(len(runs), len(cleanup))
                for command in runs:
                    self.assertIn("--init", command)
                    self.assertEqual(command[command.index("--user") + 1], "0:0")
                for command in cleanup:
                    self.assertEqual(command[-4:-2], ["-hR", "--"])
                    self.assertEqual(command[-1], "/workspace")
                    self.assertLess(commands.index(runs[0]), commands.index(command))
                self.assertEqual(receipt["status"], "failed" if code or timeout else "passed")

    def test_ownership_cleanup_failure_refuses_a_passing_receipt(self) -> None:
        with patch.object(module.sys, "platform", "linux"), \
             patch.object(module, "restore_ownership", side_effect=OSError("cleanup failed")), \
             self.assertRaisesRegex(ValueError, "ownership"):
            self.run_check()

    def test_container_removal_timeout_still_restores_owner_and_keeps_evidence(self) -> None:
        with patch.object(module.sys, "platform", "linux"):
            receipt, calls = self.run_check(cleanup_error=True)
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(receipt["consumers"][0]["exit_code"], 0)
        self.assertIn("container_cleanup_error", receipt["consumers"][0])
        self.assertIn("log_sha256", receipt["consumers"][0])
        self.assertIn("removing acceptance container failed", receipt["error"])
        self.assertTrue(any("chown" in call.args[0] for call in calls))

    def test_failure_and_timeout_keep_failed_receipts_and_stop_the_gate(self) -> None:
        for code, timeout in ((1, False), (0, True)):
            with self.subTest(code=code, timeout=timeout):
                receipt, calls = self.run_check(code, timeout)
                self.assertEqual(receipt["status"], "failed")
                self.assertEqual(len(receipt["consumers"]), 1)
                self.assertEqual(receipt["consumers"][0]["exit_code"], 124 if timeout else code)
                self.assertIn("log_sha256", receipt["consumers"][0])
                self.assertTrue(any(call.args[0][1:3] == ["rm", "--force"] for call in calls))


if __name__ == "__main__":
    unittest.main()
