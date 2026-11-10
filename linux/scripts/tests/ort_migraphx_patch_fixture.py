"""Pinned source and compiled ASan controls share setup; real SDK and GPU proof stays separate."""

from __future__ import annotations

import os
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
TESTS = ROOT / "linux/scripts/tests"
BUILD = ROOT / "linux/scripts/03-media/build/onnxruntime/build"


class MigraphxPatchFixture(unittest.TestCase):
    """Compilation must succeed before an expected sanitizer failure can prove a regression."""

    fixture_name = ""

    @classmethod
    def setUpClass(cls) -> None:
        """Both controls use the same source transport and sanitizer requirements."""
        cls.workspace = tempfile.TemporaryDirectory(prefix="mgx-ownership-")
        cls.addClassCleanup(cls.workspace.cleanup)
        cls.work = Path(cls.workspace.name)
        cls.original = cls.make_tree("original")
        cls.patched = cls.make_tree("patched")
        cls.apply_patch(cls.patched, True)
        cls.control = cls.compile_probe(cls.original, "control")
        cls.fixed = cls.compile_probe(cls.patched, "fixed")

    @classmethod
    def make_tree(cls, name: str) -> Path:
        """The patch sees the original contexts rather than a hand-recreated result."""
        tree = cls.work / name
        (tree / "src/migraphx").mkdir(parents=True)
        for filename in ("mgx_ep.h", "mgx_ep.cc", "mgx_factory.h", "mgx_factory.cc"):
            shutil.copyfile(TESTS / "fixtures/migraphx-node-compute-info" / (filename + ".txt"),
                            tree / "src/migraphx" / filename)
        return tree

    @classmethod
    def apply_patch(cls, tree: Path, succeeds: bool) -> None:
        """The production helper owns both patch order and raw failure propagation."""
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; PLUGIN_EP_CORE="$2"; MGXEP_SRC="$3"; mgxep_apply_source_patch',
             "mgx-ownership-test", str(BUILD / "35-build-migraphx-plugin-ep.sh"),
             str(ROOT / "linux/scripts/01-core"), str(tree)],
            capture_output=True, text=True, check=False, timeout=20,
        )
        if (result.returncode == 0) != succeeds:
            raise AssertionError(result.stdout + result.stderr)

    @classmethod
    def emit_definitions(cls, tree: Path, destination: Path) -> None:
        """Each case extracts the actual declarations it claims to exercise."""
        raise NotImplementedError

    @classmethod
    def compile_probe(cls, tree: Path, name: str) -> Path:
        """A compiler failure cannot satisfy a negative runtime control."""
        destination = cls.work / name
        destination.mkdir()
        cls.emit_definitions(tree, destination)
        executable = destination / "probe"
        compiler = shlex.split(os.environ.get("CXX", "c++"))
        subprocess.run(
            [*compiler, "-std=c++20", "-g", "-O0", "-fsanitize=address", "-fsized-deallocation",
             "-fno-omit-frame-pointer", "-pthread", "-I", str(destination),
             str(TESTS / "fixtures" / cls.fixture_name), "-o", str(executable)],
            check=True, capture_output=True, text=True, timeout=90,
        )
        return executable

    def run_probe(self, executable: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
        """Sanitizer settings belong to the child and remain enabled for every control."""
        env = dict(os.environ)
        env["ASAN_OPTIONS"] = "detect_leaks=1:alloc_dealloc_mismatch=1:new_delete_type_mismatch=1"
        return subprocess.run([str(executable), *arguments], env=env, capture_output=True, text=True,
                              check=False, timeout=20)
