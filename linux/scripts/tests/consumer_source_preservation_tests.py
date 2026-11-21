"""Real temporary Git trees exercise preservation only; no consumer build, source authentication or GPU proof."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
SPEC = importlib.util.spec_from_file_location(
    "consumer_source_preserver", HERE.parent / "preserve-consumer-sources.py"
)
assert SPEC is not None and SPEC.loader is not None
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)
ARCHIVE = runpy.run_path(str(HERE.parent / "restore-consumer-archive.py"))


class SourcePreservationTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="consumer-source-preservation-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.checkouts, self.output = self.root / "checkouts", self.root / "preserved"
        self.checkouts.mkdir()
        result = subprocess.run(
            ["bash", str(HERE / "consumer-source-git-fixture.sh"), str(self.root)],
            capture_output=True,
            text=True,
            check=True,
            timeout=60,
        )
        self.source = self.checkouts / "Alpha"
        Path(result.stdout.strip()).rename(self.source)
        self.plan = self.root / "plan.json"
        self.plan.write_text(json.dumps({"consumers": [{"name": "Alpha"}]}))
        self.log = self.checkouts / "Alpha.log"
        self.log.write_text("consumer started after source snapshot\n")
        self.base = M.head(self.source)
        self.working_destination = self.root / "working-copy"
        self.working_output = self.root / "working-proof"
        self.archive = self.root / "archive"
        self.destination = self.root / "restored"
        self.receipt = self.root / "archive-receipt.json"

    def preserve(self) -> dict:
        return M.preserve(self.checkouts, self.plan, self.output)

    def working(self) -> dict:
        return M.preserve_working(
            self.source, self.working_destination, self.working_output, self.base
        )

    def stage_working_change(self) -> None:
        (self.source / "source.txt").write_text("working source bytes\n")
        M.git(self.source, "add", "source.txt")

    def commit_fixture(self, root: Path, message: str) -> None:
        M.git(
            root,
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "commit",
            "-m",
            message,
        )

    def invoke_cli(self, arguments: list[str]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(HERE.parent / "preserve-consumer-sources.py"),
                *arguments,
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )

    def test_working_cli_persists_the_complete_receipt(self) -> None:
        self.stage_working_change()
        result = self.invoke_cli(
            [
                "--working-source",
                str(self.source),
                "--directory",
                str(self.working_output),
                "--destination",
                str(self.working_destination),
                "--revision",
                self.base,
            ]
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads((self.working_output / "progress.json").read_text())
        self.assertEqual(json.loads(result.stdout), record)
        self.assertEqual(record["selected_base"], self.base)
        self.assertEqual(
            M.working_files(self.working_destination), M.working_files(self.source)
        )

    def test_committed_cli_still_requires_its_plan(self) -> None:
        result = self.invoke_cli(
            ["--checkouts", str(self.checkouts), "--directory", str(self.output)]
        )
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.output.exists())

    def test_committed_recursive_and_working_copies_keep_original_origins(self) -> None:
        child = self.source / "third_party/ANTfrastructure"
        origins = ["https://github.com/example/Alpha.git", "ssh://git@example.invalid/team/Alpha.git"]
        for origin in origins:
            M.git(self.source, "config", "--add", "remote.origin.url", origin)
        M.git(child, "config", "remote.origin.url", "https://github.com/example/Vendor.git")
        self.preserve()
        self.stage_working_change()
        self.working()
        for copied in (self.output / "Alpha", self.working_destination):
            self.assertEqual(M.git(copied, "config", "--null", "--get-all", "remote.origin.url"),
                             "\0".join([*origins, ""]).encode())
        self.assertEqual(M.git(self.output / "Alpha/third_party/ANTfrastructure", "config", "--get", "remote.origin.url"),
                         b"https://github.com/example/Vendor.git\n")

    def test_clone_without_configured_origin_keeps_its_local_reference(self) -> None:
        M.git(self.source, "config", "remote.origin.url", "temporary")
        M.git(self.source, "config", "--unset-all", "remote.origin.url")
        self.working()
        self.assertEqual(M.git(self.working_destination, "config", "--get", "remote.origin.url"),
                         (str(self.source) + "\n").encode())

    def test_origin_values_keep_literal_boundaries_and_order(self) -> None:
        origins = ["-literal remote with spaces \t", "ssh://example.invalid/with\nnewline.git"]
        for origin in origins:
            M.git(self.source, "config", "--add", "--", "remote.origin.url", origin)
        M.clone_checkout(self.source, self.working_destination, self.base)
        self.assertEqual(M.git(self.working_destination, "config", "--null", "--get-all", "remote.origin.url"),
                         "\0".join([*origins, ""]).encode())

    def test_origin_read_and_write_failures_stay_fatal(self) -> None:
        M.git(self.source, "config", "remote.origin.url", "https://example.invalid/Alpha.git")
        original = M.git
        for phase in ("read", "write"):
            destination = self.root / (phase + "-copy")
            failing_root = self.source if phase == "read" else destination

            def fail_config(root: Path, *arguments: str, failing: Path = failing_root) -> bytes:
                if root == failing and arguments[0] == "config":
                    raise subprocess.CalledProcessError(47, ["git", *arguments])
                return original(root, *arguments)

            with self.subTest(phase=phase), mock.patch.object(M, "git", fail_config), \
                    self.assertRaises(subprocess.CalledProcessError) as caught:
                M.clone_checkout(self.source, destination, self.base)
            self.assertEqual(caught.exception.returncode, 47)

    def test_working_copy_keeps_selected_base_and_all_staged_bytes(self) -> None:
        (self.source / "later.txt").write_text("post-base committed bytes\n")
        M.git(self.source, "add", "later.txt")
        self.commit_fixture(self.source, "later")
        self.stage_working_change()
        record = self.working()
        self.assertEqual(M.head(self.working_destination), self.base)
        self.assertEqual(record["owner_head"], M.head(self.source))
        self.assertNotEqual(record["owner_head"], record["selected_base"])
        self.assertEqual(
            (self.working_destination / "source.txt").read_text(),
            "working source bytes\n",
        )
        self.assertEqual(
            (self.working_destination / "later.txt").read_text(),
            "post-base committed bytes\n",
        )
        self.assertFalse(record["recursive_children_preserved"])
        self.assertEqual(
            M.working_files(self.working_destination), M.working_files(self.source)
        )
        for original in (self.source / ".git/objects").glob("??/*"):
            duplicate = self.working_destination / original.relative_to(self.source)
            if duplicate.exists():
                self.assertFalse(original.samefile(duplicate))

    def test_working_copy_refuses_unstaged_changes_before_allocating(self) -> None:
        (self.source / "source.txt").write_text("not staged\n")
        with self.assertRaisesRegex(ValueError, "Stage every tracked source edit"):
            self.working()
        self.assertFalse(self.working_output.exists())

    def test_working_copy_refuses_existing_outputs_and_linked_destinations(
        self,
    ) -> None:
        self.working_destination.mkdir()
        (self.working_destination / "keep").write_text("original\n")
        with self.assertRaisesRegex(ValueError, "existing preservation tree"):
            self.working()
        self.assertEqual((self.working_destination / "keep").read_text(), "original\n")

    def test_working_copy_refuses_an_existing_evidence_directory(self) -> None:
        self.working_output.mkdir()
        with self.assertRaises(FileExistsError):
            self.working()

    def test_working_copy_refuses_source_overlap_and_partial_revision(self) -> None:
        with self.assertRaisesRegex(ValueError, "overlaps"):
            M.preserve_working(
                self.source, self.source / "copy", self.working_output, self.base
            )
        with self.assertRaisesRegex(ValueError, "overlaps"):
            M.preserve_working(
                self.source, self.source.parent, self.working_output, self.base
            )
        with self.assertRaisesRegex(ValueError, "full commit"):
            M.preserve_working(
                self.source, self.working_destination, self.working_output, "HEAD"
            )

    def test_working_copy_retains_staged_gitlink_instead_of_child_checkout(
        self,
    ) -> None:
        child = self.source / "third_party/ANTfrastructure"
        original = M.head(child)
        self.stage_working_change()
        for message in ("indexed", "checked out"):
            (child / "source.txt").write_text(message + "\n")
            M.git(child, "add", "source.txt")
            self.commit_fixture(child, message)
            if message == "indexed":
                indexed = M.head(child)
                M.git(self.source, "add", "third_party/ANTfrastructure")
        self.assertEqual(len({original, indexed, M.head(child)}), 3)
        before, child_before = (
            M.working_snapshot(self.source),
            M.working_snapshot(child),
        )
        record = self.working()
        self.assertEqual(M.working_snapshot(self.source), before)
        self.assertEqual(M.working_snapshot(child), child_before)
        self.assertEqual(M.working_snapshot(self.working_destination), before)
        self.assertEqual(
            record["versioned_paths"]["third_party/ANTfrastructure"]["revision"],
            indexed,
        )
        self.assertFalse(record["recursive_children_preserved"])

    def test_working_copy_checks_index_independently_of_file_bytes(self) -> None:
        clone = M.clone_checkout

        def changing_index(source: Path, destination: Path, revision: str) -> None:
            clone(source, destination, revision)
            M.git(
                destination,
                "update-index",
                "--cacheinfo",
                f"160000,{self.base},third_party/ANTfrastructure",
            )

        with (
            mock.patch.object(M, "clone_checkout", changing_index),
            self.assertRaisesRegex(ValueError, "Working source index differs"),
        ):
            self.working()

    def test_working_copy_detects_source_changes_during_preparation(self) -> None:
        clone = M.clone_checkout

        def changing_clone(source: Path, destination: Path, revision: str) -> None:
            clone(source, destination, revision)
            (source / "source.txt").write_text("changed after snapshot\n")

        with (
            mock.patch.object(M, "clone_checkout", changing_clone),
            self.assertRaisesRegex(ValueError, "Working source changed"),
        ):
            self.working()

    def test_working_copy_checks_actual_destination_bytes(self) -> None:
        clone = M.clone_checkout

        def corrupting_clone(source: Path, destination: Path, revision: str) -> None:
            clone(source, destination, revision)
            (destination / "source.txt").write_text("different copied bytes\n")

        with (
            mock.patch.object(M, "clone_checkout", corrupting_clone),
            self.assertRaisesRegex(ValueError, "bytes, modes or links differ"),
        ):
            self.working()

    def test_working_copy_requires_independent_complete_objects(self) -> None:
        clone = M.clone_checkout

        def borrowed_clone(source: Path, destination: Path, revision: str) -> None:
            clone(source, destination, revision)
            (destination / ".git/objects/info/alternates").write_text(
                str(source / ".git/objects") + "\n"
            )

        with (
            mock.patch.object(M, "clone_checkout", borrowed_clone),
            self.assertRaisesRegex(ValueError, "borrow or promise"),
        ):
            self.working()

    def test_working_copy_checks_all_git_objects(self) -> None:
        clone = M.clone_checkout

        def corrupt_clone(source: Path, destination: Path, revision: str) -> None:
            clone(source, destination, revision)
            corrupt = destination / ".git/objects/aa" / ("a" * 38)
            corrupt.parent.mkdir(exist_ok=True)
            corrupt.write_bytes(b"not a Git object")

        with (
            mock.patch.object(M, "clone_checkout", corrupt_clone),
            self.assertRaises(subprocess.CalledProcessError),
        ):
            self.working()

    def test_working_copy_refuses_empty_versioned_scope(self) -> None:
        M.git(self.source, "rm", "--cached", "-r", ".")
        with self.assertRaisesRegex(ValueError, "no versioned files"):
            self.working()

    def test_working_paths_refuse_unresolved_index_stages(self) -> None:
        row = b"100644 " + b"a" * 40 + b" 1\tsource.txt\0"
        with (
            mock.patch.object(M, "git", return_value=row),
            self.assertRaisesRegex(ValueError, "unresolved stages"),
        ):
            M.working_files(self.source)

    @unittest.skipIf(os.name == "nt", "Unix symlink transport is checked on Linux")
    def test_working_paths_refuse_external_parent_links(self) -> None:
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "file").write_text("external\n")
        (self.source / "escape").symlink_to(outside, target_is_directory=True)
        row = b"100644 " + b"a" * 40 + b" 0\tescape/file\0"
        with (
            mock.patch.object(M, "git", return_value=row),
            self.assertRaisesRegex(ValueError, "escapes its root"),
        ):
            M.working_files(self.source)

    @unittest.skipIf(
        os.name == "nt", "Unix mode and symlink transport is checked on Linux"
    )
    def test_working_copy_keeps_executable_modes_and_literal_links(self) -> None:
        self.stage_working_change()
        (self.source / "source.txt").chmod(0o755)
        (self.source / "alias").symlink_to("source.txt")
        M.git(self.source, "add", "source.txt", "alias")
        self.working()
        self.assertEqual(
            (self.working_destination / "source.txt").stat().st_mode & 0o777, 0o755
        )
        self.assertEqual(
            str((self.working_destination / "alias").readlink()), "source.txt"
        )

    @unittest.skipIf(os.name == "nt", "Unix file modes are checked on Linux")
    def test_working_copy_restores_actual_modes_across_umasks(self) -> None:
        (self.source / "source.txt").chmod(0o664)
        original = os.umask(0o077)
        self.addCleanup(os.umask, original)
        self.working()
        self.assertEqual(
            (self.working_destination / "source.txt").stat().st_mode & 0o777, 0o664
        )

    @unittest.skipIf(os.name == "nt", "Unix symlink transport is checked on Linux")
    def test_working_copy_refuses_linked_evidence_and_destination(self) -> None:
        self.working_destination.symlink_to(
            self.root / "absent", target_is_directory=True
        )
        with self.assertRaisesRegex(ValueError, "must not be linked"):
            self.working()
        self.working_destination.unlink()
        self.working_output.symlink_to(self.root / "absent", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "must not be linked"):
            self.working()

    def test_working_source_cli_modes_cannot_silently_mix(self) -> None:
        for extra in (
            [],
            ["--revision", self.base],
            ["--destination", str(self.working_destination)],
            [
                "--destination",
                str(self.working_destination),
                "--revision",
                self.base,
                "--plan",
                str(self.plan),
            ],
        ):
            result = subprocess.run(
                [
                    sys.executable,
                    str(HERE.parent / "preserve-consumer-sources.py"),
                    "--working-source",
                    str(self.source),
                    "--directory",
                    str(self.working_output),
                    *extra,
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 2)
        self.assertFalse(self.working_destination.exists())

    def test_exact_recursive_copies_use_independent_objects_and_survive_source_removal(
        self,
    ) -> None:
        self.assertEqual(self.preserve()["status"], "preservation-complete")
        record = json.loads((self.output / "Alpha.json").read_text())
        self.assertEqual(len(record["roots"]), 2)
        for row in record["roots"]:
            source, copy = Path(row["source"]), Path(row["preserved"])
            self.assertEqual(
                M.git(source, "ls-files", "--stage", "-z"),
                M.git(copy, "ls-files", "--stage", "-z"),
            )
            self.assertEqual(
                (copy / "source.txt").read_bytes(), (source / "source.txt").read_bytes()
            )
            objects = list((source / ".git/objects").glob("??/*"))
            self.assertTrue(objects)
            for original in objects:
                duplicate = copy / original.relative_to(source)
                self.assertFalse(original.samefile(duplicate))
        shutil.rmtree(self.source)
        self.assertEqual(self.preserve()["consumers"], ["Alpha"])

    def test_git_directory_before_consumer_log_remains_pending(self) -> None:
        self.log.unlink()
        self.assertEqual(self.preserve()["pending"], ["Alpha"])
        self.assertFalse((self.output / "Alpha").exists())

    def test_cached_working_tree_edits_fail(self) -> None:
        self.preserve()
        (self.output / "Alpha/source.txt").write_text("changed\n")
        with self.assertRaisesRegex(ValueError, "tree is dirty"):
            self.preserve()

    def test_cached_index_edits_fail(self) -> None:
        self.preserve()
        (self.output / "Alpha/source.txt").write_text("staged change\n")
        M.git(self.output / "Alpha", "add", "source.txt")
        with self.assertRaisesRegex(ValueError, "index changed"):
            self.preserve()

    def test_cached_borrowed_object_store_fails(self) -> None:
        self.preserve()
        (self.output / "Alpha/.git/objects/info/alternates").write_text(
            str(self.source / ".git/objects") + "\n"
        )
        with self.assertRaisesRegex(ValueError, "borrow or promise"):
            self.preserve()

    def test_cached_promisor_marker_fails(self) -> None:
        self.preserve()
        (self.output / "Alpha/.git/objects/pack/fixture.promisor").write_text("")
        with self.assertRaisesRegex(ValueError, "borrow or promise"):
            self.preserve()

    def test_cached_corrupt_unreferenced_object_fails_fsck(self) -> None:
        self.preserve()
        corrupt = self.output / "Alpha/.git/objects/aa" / ("a" * 38)
        corrupt.parent.mkdir(exist_ok=True)
        corrupt.write_bytes(b"not a Git object")
        with self.assertRaises(subprocess.CalledProcessError):
            self.preserve()

    def test_cached_empty_root_list_fails(self) -> None:
        self.preserve()
        path = self.output / "Alpha.json"
        record = json.loads(path.read_text())
        record["roots"] = []
        path.write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, "roots differ"):
            self.preserve()

    def test_cached_external_child_root_fails(self) -> None:
        self.preserve()
        path = self.output / "Alpha.json"
        record = json.loads(path.read_text())
        record["roots"][1]["preserved"] = str(
            self.source / "third_party/ANTfrastructure"
        )
        path.write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, "root escaped"):
            self.preserve()

    def test_unsafe_names_and_overlapping_destinations_fail(self) -> None:
        self.plan.write_text(json.dumps({"consumers": [{"name": "../outside"}]}))
        with self.assertRaisesRegex(ValueError, "Invalid consumer names"):
            self.preserve()
        with self.assertRaisesRegex(ValueError, "overlaps"):
            M.preserve(self.checkouts, self.plan, self.checkouts / "inside")

    def make_archive(self, *, shallow: bool = False) -> str:
        if shallow:
            (self.source / "committed.txt").write_text("second commit\n")
            M.git(self.source, "add", "committed.txt")
            SourcePreservationTests.commit_fixture(self, self.source, "second")
            target = self.root / "shallow-source"
            subprocess.run(
                ["git", "clone", "--depth=1", self.source.as_uri(), str(target)],
                capture_output=True,
                check=True,
            )
            self.source = target
        SourcePreservationTests.stage_working_change(self)
        (self.source / "source.txt").chmod(0o744)
        if os.name != "nt":
            (self.source / "source-link").symlink_to("source.txt")
        M.git(self.source, "add", "--all")
        self.archive.mkdir()
        self.expected = M.working_snapshot(self.source)
        (self.archive / "working.patch").write_bytes(
            M.git(self.source, "diff", "--cached", "--binary", "--full-index", "HEAD")
        )
        (self.archive / "working-index.bin").write_bytes(self.expected[1])
        (self.archive / "versioned-files.json").write_text(json.dumps(self.expected[2]))
        M.git(
            self.source, "bundle", "create", str(self.archive / "base.bundle"), "HEAD"
        )
        names = set(ARCHIVE["INPUTS"])
        if shallow:
            (self.archive / "original-shallow.bin").write_bytes(
                (self.source / ".git/shallow").read_bytes()
            )
            names.add("original-shallow.bin")
        self.manifest: dict[str, Any] = {
            "schema": 1,
            "base": self.expected[0],
            "origin": "https://github.com/example/fixture.git",
            "shallow": shallow,
            "files": {name: "" for name in names},
        }
        return self.refresh_manifest()

    def refresh_manifest(self) -> str:
        for name in self.manifest["files"]:
            self.manifest["files"][name] = hashlib.sha256(
                (self.archive / name).read_bytes()
            ).hexdigest()
        path = self.archive / "archive.json"
        path.write_text(json.dumps(self.manifest))
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def restore(self, digest: str) -> dict:
        return ARCHIVE["restore_archive"](
            self.archive, digest, self.destination, self.receipt
        )

    def test_archive_restores_exact_staged_bytes_modes_links_and_independent_objects(
        self,
    ) -> None:
        record = self.restore(self.make_archive())
        self.assertEqual(M.working_snapshot(self.destination), self.expected)
        self.assertEqual(record, json.loads(self.receipt.read_text()))
        self.assertFalse(record["recursive_dependencies_restored"])
        self.assertFalse(record["full_Git_history_claimed"])
        for original in (self.source / ".git/objects").glob("??/*"):
            duplicate = self.destination / original.relative_to(self.source)
            if duplicate.exists():
                self.assertFalse(original.samefile(duplicate))

    def test_archive_retains_original_shallow_metadata_before_checkout_and_fsck(
        self,
    ) -> None:
        record = self.restore(self.make_archive(shallow=True))
        self.assertTrue(record["original_shallow_metadata_restored"])
        self.assertEqual(
            (self.destination / ".git/shallow").read_bytes(),
            (self.source / ".git/shallow").read_bytes(),
        )
        self.assertEqual(M.working_snapshot(self.destination), self.expected)
        M.verify_objects(self.destination)

    def test_archive_refuses_manifest_digest_mismatch_before_allocation(self) -> None:
        self.make_archive()
        with self.assertRaisesRegex(ValueError, "manifest digest differs"):
            self.restore("0" * 64)
        self.assertFalse(self.destination.exists())

    def test_archive_refuses_changed_input_before_allocation(self) -> None:
        digest = self.make_archive()
        with (self.archive / "working.patch").open("ab") as stream:
            stream.write(b"changed\n")
        with self.assertRaisesRegex(ValueError, "input digest differs"):
            self.restore(digest)
        self.assertFalse(self.destination.exists())

    def test_archive_requires_the_exact_restored_index(self) -> None:
        self.make_archive()
        (self.archive / "working-index.bin").write_bytes(b"wrong index")
        with self.assertRaisesRegex(ValueError, "archive index differs"):
            self.restore(self.refresh_manifest())
        self.assertFalse(self.receipt.exists())

    def test_archive_requires_actual_working_bytes(self) -> None:
        self.make_archive()
        files = json.loads((self.archive / "versioned-files.json").read_text())
        files["source.txt"]["sha256"] = "0" * 64
        (self.archive / "versioned-files.json").write_text(json.dumps(files))
        with self.assertRaisesRegex(ValueError, "bytes, modes or links differ"):
            self.restore(self.refresh_manifest())
        self.assertFalse(self.receipt.exists())

    def test_archive_object_verification_is_required(self) -> None:
        digest = self.make_archive()
        probe = mock.Mock(side_effect=ValueError("archive object probe failed"))
        with (
            mock.patch.dict(ARCHIVE["PRESERVER"], {"verify_objects": probe}),
            self.assertRaisesRegex(ValueError, "archive object probe failed"),
        ):
            self.restore(digest)
        probe.assert_called_once()
        self.assertFalse(self.receipt.exists())

    def test_archive_rechecks_inputs_after_restoration_before_receipt(self) -> None:
        digest = self.make_archive()
        original = ARCHIVE["PRESERVER"]["restore_working_modes"]

        def changed_input(destination: Path, files: dict) -> None:
            original(destination, files)
            with (self.archive / "working.patch").open("ab") as stream:
                stream.write(b"changed after restoration\n")

        with (
            mock.patch.dict(
                ARCHIVE["PRESERVER"], {"restore_working_modes": changed_input}
            ),
            self.assertRaisesRegex(ValueError, "input digest differs"),
        ):
            self.restore(digest)
        self.assertFalse(self.receipt.exists())

    def test_archive_metadata_cannot_change_outside_paths_kinds_or_invalid_modes(
        self,
    ) -> None:
        self.make_archive()
        original = json.loads((self.archive / "versioned-files.json").read_text())
        marker = self.root / "outside"
        marker.write_text("outside the checkout")
        marker.chmod(0o644)
        cases = {
            "paths": {
                **original,
                "../outside": {"git_mode": "100644", "mode": 0, "sha256": "0" * 64},
            },
            "kinds": {
                **original,
                "source.txt": {**original["source.txt"], "git_mode": "120000"},
            },
            "mode": {**original, "source.txt": {**original["source.txt"], "mode": -1}},
            "mode-upper": {
                **original,
                "source.txt": {**original["source.txt"], "mode": 0o10000},
            },
            "mode-bool": {
                **original,
                "source.txt": {**original["source.txt"], "mode": True},
            },
        }
        for name, files in cases.items():
            with self.subTest(name=name):
                self.destination = self.root / ("invalid-" + name)
                (self.archive / "versioned-files.json").write_text(json.dumps(files))
                with self.assertRaisesRegex(
                    ValueError, "Archive metadata " + name.split("-")[0] + " differ"
                ):
                    self.restore(self.refresh_manifest())
                self.assertEqual(marker.stat().st_mode & 0o7777, 0o644)
                self.assertFalse(self.receipt.exists())

    def test_archive_preserves_existing_destination(self) -> None:
        digest = self.make_archive()
        self.destination.mkdir()
        marker = self.destination / "keep"
        marker.write_text("original")
        with self.assertRaisesRegex(ValueError, "existing archive destination"):
            self.restore(digest)
        self.assertEqual(marker.read_text(), "original")

    def test_archive_refuses_overlapping_destination(self) -> None:
        digest = self.make_archive()
        self.destination = self.archive / "inside"
        with self.assertRaisesRegex(ValueError, "destination overlaps inputs"):
            self.restore(digest)
        self.assertFalse(self.destination.exists())

    def test_archive_cli_writes_the_checked_receipt(self) -> None:
        digest = self.make_archive()
        result = subprocess.run(
            [
                sys.executable,
                str(HERE.parent / "restore-consumer-archive.py"),
                "--archive",
                str(self.archive),
                "--expected-manifest-sha256",
                digest,
                "--destination",
                str(self.destination),
                "--receipt",
                str(self.receipt),
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout), json.loads(self.receipt.read_text())
        )
        self.assertEqual(M.working_snapshot(self.destination), self.expected)


if __name__ == "__main__":
    unittest.main()
