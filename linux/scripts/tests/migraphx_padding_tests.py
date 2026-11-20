"""Compile the pinned pooling source slice; typed doubles do not prove SDK or GPU numerics."""

from __future__ import annotations

import re
import shutil
import subprocess
import unittest
from pathlib import Path

from ort_migraphx_patch_fixture import ROOT, TESTS, MigraphxPatchFixture


class MigraphxPaddingTests(MigraphxPatchFixture):
    """The max guard must retain average behavior and permit the existing LP fold."""

    fixture_name = "migraphx-padding-policy.cpp"

    @classmethod
    def make_tree(cls, name: str) -> Path:
        """Both controls start from unchanged pinned upstream files and notices."""
        tree = cls.work / name
        for directory, filename in (("src", "eliminate_pad.cpp"), ("test", "eliminate_pad_test.cpp")):
            (tree / directory).mkdir(parents=True, exist_ok=True)
            shutil.copyfile(TESTS / "fixtures/migraphx-padding" / (filename + ".txt"),
                            tree / directory / filename)
        return tree

    @classmethod
    def apply_patch(cls, tree: Path, succeeds: bool) -> None:
        """The same production patch transport must reject changed upstream context."""
        result = subprocess.run(
            ["bash", str(ROOT / "linux/scripts/01-core/apply-patch.sh"),
             str(ROOT / "linux/scripts/patches/migraphx/001-preserve-zero-pad-maxpool.patch"),
             str(tree)],
            capture_output=True, text=True, check=False, timeout=20,
        )
        if (result.returncode == 0) != succeeds:
            raise AssertionError(result.stdout + result.stderr)

    @classmethod
    def emit_definitions(cls, tree: Path, destination: Path) -> None:
        """The executable compiles the actual patched function rather than a copied policy."""
        source = (tree / "src/eliminate_pad.cpp").read_text()
        match = re.search(r"static void update_pooling\(.*?\n}\n", source, re.DOTALL)
        assert match is not None
        (destination / "pooling.inc").write_text(match[0])

    @classmethod
    def compile_probe(cls, tree: Path, name: str) -> Path:
        """A failed compiler must retain its diagnostic instead of becoming an opaque control."""
        try:
            return super().compile_probe(tree, name)
        except subprocess.CalledProcessError as error:
            raise AssertionError(error.stdout + error.stderr) from error

    def test_original_guard_rejects_max_policy(self) -> None:
        """A compiler or sanitizer failure cannot satisfy the expected policy refusal."""
        result = self.run_probe(self.control)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "MAX PAD MUST REMAIN EXPLICIT\n")

    def test_fixed_max_average_and_lp_policy(self) -> None:
        """Keeping every Pad would silently discard the unaffected LP optimization."""
        result = self.run_probe(self.fixed)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "MIGraphX pooling policy checks: 3\n")

    def test_patch_is_idempotent_and_stale_context_refuses(self) -> None:
        """A moved guard must fail before the upstream numerical test changes."""
        self.apply_patch(self.patched, True)
        stale = self.make_tree("stale")
        path = stale / "src/eliminate_pad.cpp"
        path.write_text(path.read_text().replace(
            "if(op.mode == op::pooling_mode::average)", "if(unexpected_policy(op.mode))"))
        before = (stale / "test/eliminate_pad_test.cpp").read_bytes()
        self.apply_patch(stale, False)
        self.assertEqual((stale / "test/eliminate_pad_test.cpp").read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
