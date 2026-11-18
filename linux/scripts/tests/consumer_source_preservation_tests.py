"""Real temporary Git trees exercise preservation only; no consumer build, source authentication or GPU proof."""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
SPEC = importlib.util.spec_from_file_location(
    "consumer_source_preserver", HERE.parent / "preserve-consumer-sources.py"
)
assert SPEC is not None and SPEC.loader is not None
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


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
            root, "-c", "user.name=Fixture", "-c",
            "user.email=fixture@example.invalid", "commit", "-m", message,
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

    def test_working_copy_retains_staged_gitlink_instead_of_child_checkout(self) -> None:
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
        before, child_before = M.working_snapshot(self.source), M.working_snapshot(child)
        record = self.working()
        self.assertEqual(M.working_snapshot(self.source), before)
        self.assertEqual(M.working_snapshot(child), child_before)
        self.assertEqual(M.working_snapshot(self.working_destination), before)
        self.assertEqual(
            record["versioned_paths"]["third_party/ANTfrastructure"]["revision"], indexed
        )
        self.assertFalse(record["recursive_children_preserved"])

    def test_working_copy_checks_index_independently_of_file_bytes(self) -> None:
        clone = M.clone_checkout

        def changing_index(source: Path, destination: Path, revision: str) -> None:
            clone(source, destination, revision)
            M.git(destination, "update-index", "--cacheinfo",
                  f"160000,{self.base},third_party/ANTfrastructure")

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


if __name__ == "__main__":
    unittest.main()
