"""Real temporary Git trees exercise preservation only; no consumer build, source authentication or GPU proof."""

from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

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

    def preserve(self) -> dict:
        return M.preserve(self.checkouts, self.plan, self.output)

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
