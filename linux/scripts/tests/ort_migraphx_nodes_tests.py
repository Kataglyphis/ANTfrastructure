"""Patch pinned source and compile both node types under ASan; no real SDK or GPU proof."""

from __future__ import annotations

import re
import unittest
from pathlib import Path

from ort_migraphx_patch_fixture import MigraphxPatchFixture


class MigraphxNodeTests(MigraphxPatchFixture):
    """C ABI pointer offsets and both concrete node destructors must stay observable."""

    fixture_name = "migraphx-node-cleanup-probe.cpp"

    @classmethod
    def emit_definitions(cls, tree: Path, destination: Path) -> None:
        """The fixture compiles patched declarations instead of reproducing their behavior."""
        header = (tree / "src/migraphx/mgx_ep.h").read_text()
        start = header.index("struct NodeComputeInfo")
        end = re.search(r"\n}\s*//\s*namespace mgx_ep", header)
        assert end is not None
        (destination / "nodes.inc").write_text(header[start:end.start()])
        source = (tree / "src/migraphx/mgx_ep.cc").read_text()
        start = source.index("Ort::Status ExecutionProvider::ReleaseNodeComputeInfos")
        (destination / "release.inc").write_text(source[start:])

    def test_unpatched_delete_fails_for_the_expected_type_mismatch(self) -> None:
        """A missing tool or unrelated crash cannot satisfy the original-bug control."""
        result = self.run_probe(self.control)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("new-delete-type-mismatch", result.stderr)
        self.assertNotIn("MIGraphX node cleanup checks:", result.stdout)

    def test_both_patched_types_and_callbacks_pass(self) -> None:
        """Both node variants need their C header and mixed/null cleanup exercised."""
        result = self.run_probe(self.fixed)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "MIGraphX node cleanup checks: 11\n")

    def test_every_callback_adjusts_the_c_base_pointer(self) -> None:
        """Current no-op callbacks still need correct adjustment when their bodies grow."""
        header = (self.patched / "src/migraphx/mgx_ep.h").read_text()
        for name in ("NodeComputeInfo", "EpContextNodeComputeInfo"):
            with self.subTest(node=name):
                self.assertEqual(header.count(f"static_cast<{name}*>(this_)"), 3)

    def test_patch_is_idempotent_and_stale_source_fails(self) -> None:
        """A moved deletion site must fail before the header receives half a patch."""
        self.apply_patch(self.patched, True)
        stale = self.make_tree("stale")
        source = stale / "src/migraphx/mgx_ep.cc"
        source.write_text(source.read_text().replace("delete info;", "unexpected_cleanup(info);"))
        before = (stale / "src/migraphx/mgx_ep.h").read_bytes()
        self.apply_patch(stale, False)
        self.assertEqual((stale / "src/migraphx/mgx_ep.h").read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
