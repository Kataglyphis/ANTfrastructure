"""Temporary OCI controls do not prove receipt-root completeness or exclude malicious concurrent writers."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path[:0] = [
    str(SCRIPTS),
    str(SCRIPTS / "local-proof"),
    str(SCRIPTS.parent / "host-config"),
]

import oci_archive_dedup as worker
from native_oci_layout import sha

ORIGINAL_IDLE = worker.observe_idle


class ArchiveDedupTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="OCI archive controls ")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.root = self.directory / "logs"
        self.root.mkdir()
        self.output = self.directory / "proof"
        self.review = self.directory / "candidates.json"
        self.authorization = self.directory / "authorization.json"
        self.paths = [self.blob(name) for name in ("first", "second")]
        self.refresh_review()
        patch = mock.patch.object(worker, "observe_idle")
        patch.start()
        self.addCleanup(patch.stop)

    def blob(self, name: str) -> Path:
        context = self.root / name
        (context / "blobs/sha256").mkdir(parents=True)
        content = b"identical archived layer\n"
        import hashlib

        path = context / "blobs/sha256" / hashlib.sha256(content).hexdigest()
        path.write_bytes(content)
        os.utime(path, ns=(1700000000000000000, 1700000000000000000))
        (context / "oci-layout").write_text('{"imageLayoutVersion":"1.0.0"}')
        (context / "index.json").write_text('{"schemaVersion":2,"manifests":[{}]}')
        return path

    def refresh_review(self) -> None:
        self.review.write_text(
            json.dumps(
                {"rows": [{"inodes": [{"paths": [str(path)]} for path in self.paths]}]}
            )
        )
        self.authorization.write_text(
            json.dumps(
                {
                    "allowed_actions": ["oci-archive-dedup"],
                    "owner_instruction": "fixture approval",
                    "candidates_sha256": sha(self.review),
                }
            )
        )

    def plan(self) -> dict[str, Any]:
        return worker.make_plan(
            self.review,
            sha(self.review),
            self.root,
            [self.root],
            self.output,
            self.authorization,
            "fixture-engine",
        )

    def apply(self) -> dict[str, Any]:
        path = self.output / "preview.json"
        return worker.apply_plan(path, sha(path), self.output, "fixture-engine")

    def receipt(self, data: dict[str, Any]) -> Path:
        path = self.root / "existing-receipt.json"
        path.write_text(json.dumps(data))
        return path

    def test_roundtrip_preserves_bytes_modes_times_and_paths(self) -> None:
        before = [worker.identity(path, stable=True) for path in self.paths]
        plan = self.plan()
        self.assertEqual(len(plan["groups"]), 1)
        result = self.apply()
        self.assertEqual(result["replaced_paths"], 1)
        self.assertEqual(self.paths[0].stat().st_ino, self.paths[1].stat().st_ino)
        for index, path in enumerate(self.paths):
            actual = worker.identity(path, stable=True)
            self.assertEqual(sha(path), path.name)
            self.assertEqual(
                {k: v for k, v in actual.items() if k != "st_ino"},
                {k: v for k, v in before[index].items() if k != "st_ino"},
            )

    def test_changed_candidate_digest_refuses_before_allocation(self) -> None:
        with self.assertRaisesRegex(ValueError, "manifest digest"):
            worker.make_plan(
                self.review,
                "0" * 64,
                self.root,
                [self.root],
                self.output,
                self.authorization,
                "fixture",
            )
        self.assertFalse(self.output.exists())

    def test_missing_explicit_authorization_refuses(self) -> None:
        self.authorization.write_text(
            json.dumps(
                {
                    "allowed_actions": [],
                    "owner_instruction": "fixture",
                    "candidates_sha256": sha(self.review),
                }
            )
        )
        with self.assertRaisesRegex(ValueError, "authorization"):
            self.plan()

    def test_authorization_must_bind_candidates(self) -> None:
        data = json.loads(self.authorization.read_text())
        data["candidates_sha256"] = "0" * 64
        self.authorization.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "different candidates"):
            self.plan()

    def test_duplicate_paths_refuse(self) -> None:
        self.paths.append(self.paths[0])
        self.refresh_review()
        with self.assertRaisesRegex(ValueError, "repeated"):
            self.plan()

    def test_outside_paths_refuse(self) -> None:
        self.paths.append(self.directory / "outside")
        self.refresh_review()
        with self.assertRaisesRegex(ValueError, "outside"):
            self.plan()

    def test_existing_output_refuses(self) -> None:
        self.output.mkdir()
        with self.assertRaisesRegex(ValueError, "existing proof"):
            self.plan()

    def test_overlapping_output_refuses(self) -> None:
        self.output = self.paths[0].parent / "proof"
        with self.assertRaisesRegex(ValueError, "overlaps"):
            self.plan()

    def test_blob_symlink_refuses(self) -> None:
        self.paths[1].unlink()
        self.paths[1].symlink_to(self.paths[0])
        with self.assertRaisesRegex(ValueError, "regular file"):
            self.plan()

    def test_parent_symlink_refuses(self) -> None:
        alternate = self.root / "alias"
        alternate.symlink_to(self.paths[0].parents[2], target_is_directory=True)
        self.paths[1] = alternate / "blobs/sha256" / self.paths[0].name
        self.refresh_review()
        with self.assertRaisesRegex(AssertionError, "symlink"):
            self.plan()

    def test_non_OCI_layout_refuses(self) -> None:
        (self.paths[0].parents[2] / "oci-layout").write_text(
            '{"imageLayoutVersion":"0"}'
        )
        with self.assertRaisesRegex(ValueError, "OCI layout"):
            self.plan()

    def test_changed_blob_bytes_refuse(self) -> None:
        self.paths[1].write_bytes(b"changed archive")
        with self.assertRaisesRegex(ValueError, "SHA256"):
            self.plan()

    def test_unowned_file_refuses(self) -> None:
        with (
            mock.patch.object(worker.os, "getuid", return_value=os.getuid() + 1),
            self.assertRaisesRegex(ValueError, "owned regular"),
        ):
            self.plan()

    def test_mtime_difference_is_not_coalesced(self) -> None:
        os.utime(self.paths[1], ns=(1700000001000000000, 1700000001000000000))
        self.assertEqual(self.plan()["groups"], [])

    def test_mode_difference_is_not_coalesced(self) -> None:
        self.paths[1].chmod(0o600)
        self.assertEqual(self.plan()["groups"], [])

    def test_external_hardlinks_are_not_touched(self) -> None:
        os.link(self.paths[0], self.directory / "outside-link")
        self.assertEqual(self.plan()["groups"], [])

    def test_existing_shared_inode_is_not_counted_twice(self) -> None:
        self.paths[1].unlink()
        os.link(self.paths[0], self.paths[1])
        self.assertEqual(self.plan()["groups"], [])

    def test_receipt_bound_file_identity_is_not_touched(self) -> None:
        before = self.paths[0].stat()
        self.receipt(
            {"identity": {"st_ino": before.st_ino, "st_ctime_ns": before.st_ctime_ns}}
        )
        self.assertEqual(self.plan()["groups"], [])
        self.apply()
        self.assertEqual(self.paths[0].stat().st_ctime_ns, before.st_ctime_ns)

    def test_receipt_bound_directory_is_not_touched(self) -> None:
        self.receipt({"parent_inode": self.paths[0].parent.stat().st_ino})
        self.assertEqual(self.plan()["groups"], [])

    def test_escaped_receipt_identity_keys_are_observed(self) -> None:
        path = self.root / "escaped.json"
        path.write_text('{"st\\u005fino":' + str(self.paths[0].stat().st_ino) + "}")
        self.assertEqual(self.plan()["groups"], [])

    def test_positional_identity_and_string_inode_are_observed(self) -> None:
        for value in (
            {"identity": [str(self.paths[0].stat().st_ino)]},
            {"inode": self.paths[0].stat().st_ino},
        ):
            self.assertIn(self.paths[0].stat().st_ino, worker.identity_numbers(value))

    def test_malformed_identity_receipt_refuses(self) -> None:
        (self.root / "broken.json").write_text('{"st_ino":')
        with self.assertRaises(ValueError):
            self.plan()

    def test_unrelated_malformed_manifest_remains_fingerprinted(self) -> None:
        path = self.root / "flutter-manifest.json"
        path.write_text('{"description":"cupertino widgets", "icons":[{},],}')
        before = path.read_bytes()
        plan = self.plan()
        self.assertIn(str(path), plan["protected_receipt_sha256"])
        self.assertEqual(len(plan["groups"]), 1)
        self.apply()
        self.assertEqual(path.read_bytes(), before)

    def test_malformed_escaped_identity_key_refuses(self) -> None:
        (self.root / "escaped-broken.json").write_text(r'{"st_\u0069no":')
        with self.assertRaises(ValueError):
            self.plan()

    def test_quoted_payload_identity_is_not_a_receipt_key(self) -> None:
        data = json.dumps({"description": json.dumps({"st_ino": 123})}).encode()
        self.assertFalse(worker.identity_key_present(data))

    def test_large_escaped_payload_scan_is_bounded(self) -> None:
        code = (
            "import sys,json; sys.path[:0]=json.loads(sys.argv[1]); "
            "import oci_archive_dedup as worker; "
            "data=json.dumps({'description':'\\\"quoted payload\\\" '*20000}).encode(); "
            "assert not worker.identity_key_present(data)"
        )
        result = subprocess.run(
            [sys.executable, "-B", "-c", code, json.dumps(sys.path)],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_receipt_alias_target_identities_are_protected(self) -> None:
        target = self.directory / "external-proof.json"
        target.write_text(
            json.dumps({"identity": {"st_ino": self.paths[0].stat().st_ino}})
        )
        (self.root / "latest.json").symlink_to(target)
        self.assertEqual(self.plan()["groups"], [])

    def test_dangling_receipt_alias_is_pinned_and_preserved(self) -> None:
        path = self.root / "absent.json"
        path.symlink_to("not-created.json")
        self.assertIn(str(path), self.plan()["protected_receipt_sha256"])
        self.apply()
        self.assertTrue(path.is_symlink())
        self.assertEqual(os.readlink(path), "not-created.json")

    def test_changed_receipt_alias_refuses_before_mutation(self) -> None:
        paths = [self.directory / name for name in ("a-proof.json", "b-proof.json")]
        for path in paths:
            path.write_text('{"status":"fixture"}')
        alias = self.root / "latest.json"
        alias.symlink_to(paths[0])
        self.plan()
        alias.unlink()
        alias.symlink_to(paths[1])
        with self.assertRaisesRegex(ValueError, "Receipt protection"):
            self.apply()
        self.assertFalse((self.output / "journal.jsonl").exists())

    def test_receipt_alias_to_directory_refuses(self) -> None:
        path = self.root / "directory.json"
        path.symlink_to(self.directory, target_is_directory=True)
        with self.assertRaisesRegex(AssertionError, "regular files"):
            worker.receipt_data(path)

    def test_receipt_mutated_during_reading_refuses(self) -> None:
        path = self.receipt({"identity": "original"})
        original = Path.read_bytes

        def changing(selected: Path) -> bytes:
            data = original(selected)
            if selected == path:
                selected.write_bytes(data + b" ")
            return data

        with (
            mock.patch.object(Path, "read_bytes", changing),
            self.assertRaisesRegex(ValueError, "Receipt changed"),
        ):
            worker.receipt_data(path)

    def test_nested_source_checkout_refuses(self) -> None:
        (self.paths[0].parents[2] / ".git").mkdir()
        with self.assertRaisesRegex(ValueError, "source checkout"):
            self.plan()

    def test_repository_above_archive_root_does_not_hide_ignored_archives(self) -> None:
        (self.directory / ".git").mkdir()
        self.assertEqual(len(self.plan()["groups"]), 1)

    def test_preview_digest_is_required(self) -> None:
        self.plan()
        with self.assertRaisesRegex(ValueError, "Preview digest"):
            worker.apply_plan(
                self.output / "preview.json", "0" * 64, self.output, "fixture"
            )

    def test_changed_candidates_refuse_application(self) -> None:
        self.plan()
        self.review.write_text(self.review.read_text() + " ")
        with self.assertRaisesRegex(ValueError, "Candidate input"):
            self.apply()

    def test_changed_authorization_refuses_application(self) -> None:
        self.plan()
        self.authorization.write_text(self.authorization.read_text() + " ")
        with self.assertRaisesRegex(ValueError, "Authorization changed"):
            self.apply()

    def test_new_receipt_refuses_application(self) -> None:
        self.plan()
        self.receipt({"st_ino": self.paths[0].stat().st_ino})
        with self.assertRaisesRegex(ValueError, "Receipt protection"):
            self.apply()

    def test_changed_receipt_bytes_refuse_application(self) -> None:
        path = self.receipt({"identity": "old"})
        self.plan()
        path.write_text('{"identity":"new"}')
        with self.assertRaisesRegex(ValueError, "Receipt protection"):
            self.apply()

    def test_changed_file_identity_refuses_application(self) -> None:
        self.plan()
        replacement = self.directory / "replacement"
        replacement.write_bytes(self.paths[1].read_bytes())
        os.utime(replacement, ns=(1700000000000000000, 1700000000000000000))
        os.replace(replacement, self.paths[1])
        with self.assertRaisesRegex(ValueError, "identity"):
            self.apply()
        self.assertFalse((self.output / "journal.jsonl").exists())

    def test_apply_cannot_be_repeated(self) -> None:
        self.plan()
        self.apply()
        with self.assertRaisesRegex(ValueError, "repeated"):
            self.apply()

    def test_atomic_replace_failure_keeps_original_and_removes_temporary_link(
        self,
    ) -> None:
        self.plan()
        before = self.paths[1].stat().st_ino
        with (
            mock.patch.object(
                worker.os, "replace", side_effect=OSError("fixture replace refusal")
            ),
            self.assertRaisesRegex(OSError, "replace refusal"),
        ):
            self.apply()
        self.assertEqual(self.paths[1].stat().st_ino, before)
        self.assertFalse(list(self.paths[1].parent.glob(".oci-dedup-*")))
        self.assertFalse((self.output / "apply-receipt.json").exists())

    def test_actual_post_link_corruption_fails_without_success_receipt(self) -> None:
        self.plan()
        original = worker.replace_blob

        def corrupt(source: Path, destination: Path) -> None:
            original(source, destination)
            destination.write_bytes(b"bad bytes")

        with (
            mock.patch.object(worker, "replace_blob", side_effect=corrupt),
            self.assertRaisesRegex(ValueError, "SHA256"),
        ):
            self.apply()
        self.assertFalse((self.output / "apply-receipt.json").exists())

    def test_post_verifier_is_required(self) -> None:
        self.plan()
        with (
            mock.patch.object(
                worker,
                "verify_applied",
                side_effect=RuntimeError("required post control"),
            ),
            self.assertRaisesRegex(RuntimeError, "required post control"),
        ):
            self.apply()
        self.assertFalse((self.output / "apply-receipt.json").exists())

    def test_idle_gate_rejects_units_and_unknown_container_states(self) -> None:
        with (
            mock.patch.object(worker, "checked_output", return_value="live unit"),
            mock.patch.object(worker, "engine_json_lines"),
            self.assertRaisesRegex(ValueError, "unit is running"),
        ):
            ORIGINAL_IDLE("engine", self.directory, "fixture")
        for rows in ([{}], [{"Status": "Up 1 minute"}], [{"Status": "Paused"}]):
            with (
                mock.patch.object(worker, "checked_output", return_value=""),
                mock.patch.object(worker, "engine_json_lines", return_value=rows),
                self.assertRaisesRegex(ValueError, "unknown state"),
            ):
                ORIGINAL_IDLE("engine", self.directory, "fixture")

    def test_idle_gate_retains_buildkit_busy_and_unknown_refusals(self) -> None:
        for rows in ([{"inUse": True}], [{}]):
            with (
                mock.patch.object(
                    worker, "checked_output", side_effect=["", json.dumps(rows)]
                ),
                mock.patch.object(worker, "engine_json_lines", return_value=[]),
                self.assertRaisesRegex(ValueError, "BuildKit"),
            ):
                ORIGINAL_IDLE("engine", self.directory, "fixture")

    def test_idle_gate_runs_before_preview_and_application(self) -> None:
        with (
            mock.patch.object(
                worker,
                "observe_idle",
                side_effect=RuntimeError("mandatory idle control"),
            ),
            self.assertRaisesRegex(RuntimeError, "mandatory idle"),
        ):
            self.plan()
        self.output = self.directory / "second-proof"
        self.plan()
        with (
            mock.patch.object(
                worker,
                "observe_idle",
                side_effect=RuntimeError("mandatory idle control"),
            ),
            self.assertRaisesRegex(RuntimeError, "mandatory idle"),
        ):
            self.apply()
        self.assertFalse((self.output / "journal.jsonl").exists())

    def test_real_cli_preview_and_apply_with_stubbed_host_transports(self) -> None:
        binary = self.directory / "bin"
        binary.mkdir()
        for name, body in {
            "systemctl": "exit 0",
            "nerdctl": "exit 0",
            "buildctl": "printf '[]\\n'",
        }.items():
            path = binary / name
            path.write_text("#!/bin/sh\n" + body + "\n")
            path.chmod(0o755)
        common = [
            sys.executable,
            str(SCRIPTS.parent / "host-config/deduplicate-oci-archives.py"),
        ]
        for action in ("preview", "apply"):
            review = (
                self.review if action == "preview" else self.output / "preview.json"
            )
            command = common + [
                action,
                "--review",
                str(review),
                "--expected-sha256",
                sha(review),
                "--directory",
                str(self.output),
                "--engine",
                str(binary / "nerdctl"),
            ]
            if action == "preview":
                command += [
                    "--root",
                    str(self.root),
                    "--receipt-root",
                    str(self.root),
                    "--authorization",
                    str(self.authorization),
                ]
            result = subprocess.run(
                command,
                capture_output=True,
                text=True,
                check=False,
                timeout=30,
                env=dict(
                    os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"]
                ),
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.paths[0].stat().st_ino, self.paths[1].stat().st_ino)


if __name__ == "__main__":
    unittest.main()
