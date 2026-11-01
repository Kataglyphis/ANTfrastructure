#!/usr/bin/env python3
"""Prove the resolver tests reject parseable identity and API gate mutations."""

from __future__ import annotations

import ast
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PY_SOURCE = "shared/python/resolve_gpu_producer_receipt.py"
ACTION = ".github/actions/resolve-gpu-producer/action.yml"
FIXTURES = (
    PY_SOURCE,
    "shared/python/gpu_artifact_receipt.py",
    "shared/python/tests/test_resolve_gpu_producer_receipt.py",
    "shared/python/tests/test_resolve_gpu_producer_action.js",
    ACTION,
)
MUTANTS = (
    (
        PY_SOURCE,
        "if any(identity[key] != value for key, value in expected.items()):",
        "if False and any(identity[key] != value for key, value in expected.items()):",
        "python",
    ),
    (
        PY_SOURCE,
        '"artifact_id": artifact_id,',
        '"artifact_id": identity["artifact_id"],',
        "python",
    ),
    (
        PY_SOURCE,
        '"artifact_digest": artifact_digest.removeprefix("sha256:"),',
        '"artifact_digest": identity["artifact_digest"],',
        "python",
    ),
    (
        ACTION,
        "matched.length !== 1 || !matched[0].digest",
        "matched.length < 1 || !matched[0].digest",
        "node",
    ),
    (
        ACTION,
        "process.env.RUNNER_OS !== 'Linux' || !['linux', 'windows'].includes(process.env.GPU_PLATFORM)",
        "false",
        "node",
    ),
    (
        ACTION,
        "item.expired === false",
        "true",
        "node",
    ),
    (
        PY_SOURCE,
        'if layout not in {"installers", "zip-installers"}:',
        'if False and layout not in {"installers", "zip-installers"}:',
        "python",
    ),
    (
        PY_SOURCE,
        "if not expected <= set(names):",
        "if False and not expected <= set(names):",
        "python",
    ),
    (
        PY_SOURCE,
        "or not (set(names) - expected) <= certificates:",
        "or False:",
        "python",
    ),
    (
        PY_SOURCE,
        'version.extend(["0"] * (4 - len(version)))',
        'version.extend(["1"] * (4 - len(version)))',
        "python",
    ),
    (
        PY_SOURCE,
        "or not extra <= optional:",
        "or False:",
        "python",
    ),
)


class ResolverMutations(unittest.TestCase):
    """Ensure omission of identity, uniqueness or Linux guards is caught."""

    def test_parseable_gate_mutants_are_rejected(self) -> None:
        """Each mutant must fail its actual fixture assertions, not its parser."""
        node = shutil.which("node")
        if node is None:
            self.fail("node is required for the action mutation fixtures")
        for target, original, replacement, runtime in MUTANTS:
            with (
                self.subTest(target=target, original=original),
                tempfile.TemporaryDirectory() as temp,
            ):
                root = Path(temp)
                for name in FIXTURES:
                    destination = root / name
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(ROOT / name, destination)
                path = root / target
                content = path.read_text(encoding="utf-8")
                self.assertEqual(content.count(original), 1)
                mutated = content.replace(original, replacement, 1)
                if runtime == "python":
                    ast.parse(mutated)
                    command = [
                        sys.executable,
                        "-I",
                        str(
                            root
                            / "shared/python/tests/test_resolve_gpu_producer_receipt.py"
                        ),
                    ]
                else:
                    command = [
                        node,
                        str(
                            root
                            / "shared/python/tests/test_resolve_gpu_producer_action.js"
                        ),
                    ]
                path.write_text(mutated, encoding="utf-8")
                result = subprocess.run(
                    command, text=True, capture_output=True, check=False
                )
                self.assertNotEqual(result.returncode, 0, "mutant survived")
                self.assertIn("AssertionError", result.stdout + result.stderr)
                self.assertNotIn("SyntaxError", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
