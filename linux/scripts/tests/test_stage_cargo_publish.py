#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Test atomic Cargo-license directory publication; this does not validate license contents."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType


def load_collector() -> ModuleType:
    source = (
        Path(__file__).resolve().parent.parent
        / "06-packaging"
        / "stage-cargo-licenses.py"
    )
    spec = importlib.util.spec_from_file_location("stage_cargo_licenses", source)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load collector: {source}")
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(source.parent))
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path.pop(0)
    return module


class PublishDirectoryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="cargo-license-publish-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.stage = self.root / "stage"
        self.stage.mkdir()
        (self.stage / "LICENSE").write_bytes(b"original text\n")
        self.output = self.root / "output"
        self.collector = load_collector()

    def test_publishes_complete_directory(self) -> None:
        self.collector.publish_directory(self.stage, self.output)
        self.assertFalse(self.stage.exists())
        self.assertEqual((self.output / "LICENSE").read_bytes(), b"original text\n")

    def test_existing_empty_directory_is_preserved(self) -> None:
        self.output.mkdir()
        with self.assertRaises(FileExistsError):
            self.collector.publish_directory(self.stage, self.output)
        self.assertTrue(self.output.is_dir())
        self.assertTrue((self.stage / "LICENSE").is_file())

    def test_existing_file_is_preserved(self) -> None:
        self.output.write_bytes(b"untouched")
        with self.assertRaises(FileExistsError):
            self.collector.publish_directory(self.stage, self.output)
        self.assertEqual(self.output.read_bytes(), b"untouched")
        self.assertTrue((self.stage / "LICENSE").is_file())


if __name__ == "__main__":
    unittest.main()
