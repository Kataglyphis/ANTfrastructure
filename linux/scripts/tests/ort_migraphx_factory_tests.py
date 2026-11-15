"""Compile pinned registry declarations and callbacks; fake SDK ownership is not GPU proof."""

from __future__ import annotations

import re
import unittest
from pathlib import Path

from ort_migraphx_patch_fixture import MigraphxPatchFixture


class MigraphxFactoryTests(MigraphxPatchFixture):
    """The cached registry needs one owner through retries, concurrency and destruction."""

    fixture_name = "migraphx-registry-probe.cpp"

    @classmethod
    def emit_definitions(cls, tree: Path, destination: Path) -> None:
        """Source member order remains part of the compiled destruction-order check."""
        header = (tree / "src/migraphx/mgx_factory.h").read_text()
        members = [line for line in header.splitlines()
                   if re.search(r"\b(?:kernel_registry_|kernel_registry_mutex_|data_transfer_)\b", line)]
        (destination / "registry-members.inc").write_text("\n".join(members) + "\n")
        source = (tree / "src/migraphx/mgx_factory.cc").read_text()
        match = re.search(r"Ort::Status ProviderFactory::GetKernelRegistry\([^\n]+\{.*?\n}", source, re.DOTALL)
        assert match is not None
        (destination / "registry-function.inc").write_text(match[0] + "\n")

    def test_unpatched_registry_leaks(self) -> None:
        """The original raw cached pointer must fail leak detection after factory teardown."""
        result = self.run_probe(self.control, "--leak-control")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("LeakSanitizer: detected memory leaks", result.stderr)
        self.assertIn("MIGraphX raw registry control completed", result.stdout)

    def test_owned_registry_retries_and_serializes_creation(self) -> None:
        """No-kernel, failed-create and parallel callers must preserve one owned registry."""
        result = self.run_probe(self.fixed)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "MIGraphX registry checks: 41\n")

    def test_registry_patch_is_idempotent_and_refuses_stale_source(self) -> None:
        """A changed factory callback must not leave a partially rewritten header."""
        self.apply_patch(self.patched, True)
        stale = self.make_tree("stale-factory")
        source = stale / "src/migraphx/mgx_factory.cc"
        source.write_text(source.read_text().replace("kernel_registry_));", "different_registry_));"))
        before = (stale / "src/migraphx/mgx_factory.h").read_bytes()
        self.apply_patch(stale, False)
        self.assertEqual((stale / "src/migraphx/mgx_factory.h").read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
