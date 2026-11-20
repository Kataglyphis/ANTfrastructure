"""Private filesystem and child-process controls do not prove compiler hits, host locking or build acceptance."""

from __future__ import annotations

import argparse
import importlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Callable, Iterator
from contextlib import AbstractContextManager
from pathlib import Path
from typing import TYPE_CHECKING
from unittest import mock

if TYPE_CHECKING:
    from mutation_parse import MutationEntry

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "docs/scripts"))
GATE = importlib.import_module("verify_mutations")


class MutationWorkspaceTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="mutation-workspace-")
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name).resolve()
        scratch = self.home / "scratch"
        scratch.mkdir()
        temporary_root = mock.patch.object(GATE.tempfile, "tempdir", str(scratch))
        temporary_root.start()
        self.addCleanup(temporary_root.stop)
        self.source = self.home / "source"
        self.source.mkdir()
        self.workspace = self.home / "private-workspace"
        self.subject = self.source / "subject.txt"
        self.subject.write_text("on\n")

    def pool(self, requested: str | None = None) -> AbstractContextManager[Callable[[], str]]:
        return GATE.mutation_workspaces(str(self.source), requested)

    def assert_source(self) -> None:
        self.assertEqual(self.subject.read_text(), "on\n")

    def refuse(self, requested: str, error: type[Exception]) -> None:
        entered = False
        with self.assertRaises(error), self.pool(requested):
            entered = True
        self.assertFalse(entered, "refusal must precede the workspace body")

    def link(self, target: Path, path: Path) -> None:
        try:
            path.symlink_to(target, target_is_directory=True)
        except OSError as error:
            if os.name != "nt":
                raise
            self.skipTest(f"Windows directory symlink privilege unavailable: {error}")

    def test_fixed_slots_repeat_only_after_complete_owned_cleanup(self) -> None:
        for _repeat in range(2):
            with self.pool(str(self.workspace)) as allocate:
                paths = [Path(allocate()), Path(allocate())]
                self.assertEqual(paths, [self.workspace / "worker-0", self.workspace / "worker-1"])
                self.assertTrue(all(path.is_dir() for path in paths))
            self.assertFalse(self.workspace.exists())
        self.assert_source()

    def test_default_mirrors_remain_random_and_disposable(self) -> None:
        with self.pool() as allocate:
            paths = [Path(allocate()) for _slot in range(3)]
            self.assertEqual(len(set(paths)), 3)
            self.assertTrue(all(path.name.startswith("mutation-gate-") for path in paths))
        self.assertTrue(all(not path.exists() for path in paths))

    def test_copy_failure_aborts_before_returning_an_incomplete_mirror(self) -> None:
        destination = self.home / "failed-copy"
        with mock.patch.object(GATE.shutil, "copy2", side_effect=OSError("fixture copy failure")), \
             self.assertRaisesRegex(SystemExit, "mirror_tree: could not copy .*fixture copy failure"):
            GATE.mirror_tree(str(self.source), str(destination))
        self.assert_source()

    def test_relative_non_normalized_and_source_overlapping_roots_refuse(self) -> None:
        choices = ["relative", str(self.home) + os.sep + ".." + os.sep + "unexpected",
                   str(self.home) + os.sep + "." + os.sep + "unexpected",
                   str(self.source / "nested"), str(self.source), str(self.home)]
        for requested in choices:
            with self.subTest(requested=requested):
                self.refuse(requested, ValueError)
        self.assert_source()

    def test_existing_files_and_directories_remain_untouched(self) -> None:
        for directory in (False, True):
            path = self.home / str(directory)
            if directory:
                path.mkdir()
                sentinel = path / "keep.txt"
            else:
                sentinel = path
            sentinel.write_text("keep")
            with self.subTest(directory=directory):
                self.refuse(str(path), FileExistsError)
            self.assertEqual(sentinel.read_text(), "keep")

    def test_linked_roots_and_parents_refuse_without_touching_the_target(self) -> None:
        destination = self.home / "destination"
        destination.mkdir()
        sentinel = destination / "keep.txt"
        sentinel.write_text("keep")
        self.link(destination, self.workspace)
        for requested, error in [(str(self.workspace), FileExistsError),
                                 (str(self.workspace / "nested"), ValueError)]:
            with self.subTest(requested=requested):
                self.refuse(requested, error)
        self.assertEqual(sentinel.read_text(), "keep")

    def test_callback_failure_still_cleans_its_new_root(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "^callback failed$"), self.pool(str(self.workspace)) as allocate:
            Path(allocate(), "payload.txt").write_text("disposable")
            raise RuntimeError("callback failed")
        self.assertFalse(self.workspace.exists())
        self.assert_source()

    def test_replaced_root_is_never_removed(self) -> None:
        held = self.home / "held"
        with self.assertRaisesRegex(ValueError, "identity changed"), self.pool(str(self.workspace)) as allocate:
            allocate()
            self.workspace.rename(held)
            self.workspace.mkdir()
            (self.workspace / "keep.txt").write_text("replacement")
        self.assertEqual((self.workspace / "keep.txt").read_text(), "replacement")
        self.assertTrue((held / "worker-0").is_dir())

    def test_changed_parent_refuses_even_when_the_root_inode_survives(self) -> None:
        parent = self.home / "parent"
        parent.mkdir()
        root = parent / "work"
        held = self.home / "held-parent"
        with self.assertRaisesRegex(ValueError, "identity changed"), self.pool(str(root)) as allocate:
            allocate()
            parent.rename(held)
            self.link(held, parent)
        self.assertTrue((held / "work/worker-0").is_dir())

    def test_explicit_cleanup_failure_cannot_become_success(self) -> None:
        original = GATE.shutil.rmtree

        def remove(path: str | Path, ignore_errors: bool = False) -> None:
            if Path(path) == self.workspace:
                if not ignore_errors:
                    raise PermissionError("fixture cleanup failed")
                return None
            return original(path, ignore_errors=ignore_errors)

        with mock.patch.object(GATE.shutil, "rmtree", side_effect=remove), \
             self.assertRaisesRegex(PermissionError, "fixture cleanup failed"), self.pool(str(self.workspace)) as allocate:
            allocate()
        self.assertTrue(self.workspace.is_dir())

    def fixture(self, survives: bool = False) -> MutationEntry:
        check = self.source / "check.py"
        receipt = self.home / "executed-paths.txt"
        check.write_text("from pathlib import Path\n"
                         f"with Path({str(receipt)!r}).open('a') as output: output.write(str(Path.cwd()) + '\\n')\n"
                         + ("" if survives else "assert Path('subject.txt').read_text() == 'on\\n'\n"))
        entry: MutationEntry = {"id": "fixture", "target": "subject.txt", "find": "on", "replace": "off",
                 "test": f'"{sys.executable}" check.py', "why": "A fixture must detect the changed subject."}
        (self.source / "mutations.json").write_text(json.dumps([entry]))
        return entry

    def cli(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, str(ROOT / "docs/scripts/verify_mutations.py"),
                               "--root", str(self.source), "--manifest", str(self.source / "mutations.json"),
                               "--jobs", "1", "--workspace-root", str(self.workspace), *arguments],
                              text=True, capture_output=True, check=False, timeout=45)

    def test_real_cli_keeps_the_source_and_runs_both_controls_in_its_fixed_slot(self) -> None:
        self.fixture()
        result = self.cli()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("coverage: proved 1 of 1: the whole manifest", result.stdout)
        self.assertEqual((self.home / "executed-paths.txt").read_text().splitlines(),
                         [str(self.workspace / "worker-0")] * 2)
        self.assertFalse(self.workspace.exists())
        self.assert_source()

    def test_real_cli_retains_surviving_mutation_failure_and_cleanup(self) -> None:
        self.fixture(survives=True)
        result = self.cli()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("SURVIVED", result.stdout + result.stderr)
        self.assertFalse(self.workspace.exists())
        self.assert_source()

    def test_check_modes_allocate_nothing_and_in_place_combination_refuses(self) -> None:
        self.fixture()
        for argument, expected in [("--stale-check", 0), ("--parse-check", 0), ("--in-place", 2)]:
            result = self.cli(argument)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
            self.assertFalse(self.workspace.exists())
        self.assert_source()

    def test_prover_forwards_the_same_owned_allocator_to_shards(self) -> None:
        entry = self.fixture()
        args = argparse.Namespace(root=str(self.source), in_place=False, setup_script=None,
                                  workspace_root=str(self.workspace), jobs=2)
        forwarded = []

        def shards(parsed: argparse.Namespace, _entries: list[MutationEntry], source: str,
                   _report: object, _costs: object, *, allocate: Callable[[], str]) -> int:
            forwarded.append(True)
            self.assertEqual(parsed.root, str(self.workspace / "worker-0"))
            self.assertEqual(source, str(self.source))
            self.assertEqual(allocate(), str(self.workspace / "worker-1"))
            return 0

        with mock.patch.object(GATE, "run_shards", side_effect=shards):
            self.assertEqual(GATE.prove_in_mirrors(args, [entry], GATE.Report()), 0)
        self.assertEqual(forwarded, [True])
        self.assertFalse(self.workspace.exists())

    def test_parallel_shards_use_owned_fixed_slots_without_changing_the_source(self) -> None:
        observed: list[str] = []
        entries: list[MutationEntry] = [self.fixture(), {**self.fixture(), "id": "second"}]
        with self.pool(str(self.workspace)) as allocate:
            root = allocate()
            args = argparse.Namespace(root=root, jobs=2, setup_script=None)

            def shard(_args: argparse.Namespace, _entries: Iterator[MutationEntry], path: str, *_rest: object) -> int:
                observed.append(path)
                return 0

            with mock.patch.object(GATE, "mirror_cap", return_value=2), \
                 mock.patch.object(GATE, "run_shard", side_effect=shard):
                self.assertEqual(GATE.run_shards(args, entries, str(self.source), GATE.Report(), allocate=allocate), 0)
            self.assertEqual(set(observed), {str(self.workspace / "worker-0"), str(self.workspace / "worker-1")})
        self.assertFalse(self.workspace.exists())
        self.assert_source()


if __name__ == "__main__":
    unittest.main()
