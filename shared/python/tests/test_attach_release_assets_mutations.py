#!/usr/bin/env python3
"""Ensure release identity, published status and collision checks have teeth."""

from __future__ import annotations

import ast
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SOURCE = "shared/python/attach_release_assets.py"
TEST = "shared/python/tests/test_attach_release_assets.py"
MUTANTS = (
    (
        "if tag_commit(repo, tag) != revision:",
        "if False and tag_commit(repo, tag) != revision:",
    ),
    (
        "if occupied.intersection(p.name.casefold() for p in files):",
        "if False and occupied.intersection(p.name.casefold() for p in files):",
    ),
    ('release.get("draft") is not False', 'release.get("draft") is None'),
)


class AttachmentMutations(unittest.TestCase):
    """Require the real fixtures to fail for each parseable gate mutation."""

    def test_release_gate_mutations_are_rejected(self) -> None:
        """Each mutant must fail an assertion, not just fail to parse."""
        for original, replacement in MUTANTS:
            with self.subTest(original=original), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                for name in (SOURCE, TEST):
                    target = root / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(ROOT / name, target)
                path = root / SOURCE
                content = path.read_text(encoding="utf-8")
                self.assertEqual(content.count(original), 1)
                mutated = content.replace(original, replacement, 1)
                ast.parse(mutated)
                path.write_text(mutated, encoding="utf-8")
                result = subprocess.run(
                    [sys.executable, "-I", str(root / TEST)],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(result.returncode, 0, "mutant survived")
                self.assertIn("AssertionError", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
