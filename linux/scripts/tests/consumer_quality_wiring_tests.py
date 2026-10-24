#!/usr/bin/env python3
"""A removed ratchet argument must fail before weekly inventory reports green."""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from verify_consumer_quality_wiring import inspect  # noqa: E402

REL = ".github/workflows/quality.yml"


def _write(root: Path, text: str) -> Path:
    path = root / REL
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def _git(root: Path) -> None:
    subprocess.run(["git", "-C", str(root), "init", "-q"], check=True)
    subprocess.run(["git", "-C", str(root), "add", "."], check=True)
    subprocess.run(["git", "-c", "user.name=Fixture", "-c",
                    "user.email=fixture@example.invalid", "-C", str(root),
                    "commit", "-qm", "fixture"], check=True)


class QualityWiringTests(unittest.TestCase):
    def setUp(self) -> None:
        self.work = tempfile.TemporaryDirectory(prefix="consumer-quality-")
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)

    def check(self, workflow: str, tracked: list[str] | None = None):
        _write(self.root, workflow)
        return inspect(self.root, [REL] if tracked is None else tracked)

    def test_reusable_ratchet_mutation(self):
        good = ("on: push\njobs:\n  lint:\n    uses: Kataglyphis/ANTfrastructure/"
                ".github/workflows/lint-gates.yml@develop\n    with:\n      ratchets: true\n")
        witnesses, failures = self.check(good)
        self.assertEqual(1, len(witnesses))
        self.assertEqual([], failures)
        for broken in (good.replace("ratchets: true", "ratchets: false"),
                       good.replace("      ratchets: true\n", ""),
                       good.replace("ratchets: true", "ratchets: ${{ inputs.ratchets }}")):
            witnesses, failures = self.check(broken)
            self.assertEqual([], witnesses)
            self.assertIn("ratchets: true", failures[0])

    def test_direct_ratchet_mutation(self):
        good = ("on: push\njobs:\n  lint:\n    runs-on: ubuntu-26.04\n"
                "    steps:\n      - run: bash antfrastructure-tools/linux/scripts/"
                "run-lint-gates.sh . --ratchets\n")
        self.assertEqual((1, 0), tuple(map(len, self.check(good))))
        witnesses, failures = self.check(good.replace(" --ratchets", ""))
        self.assertEqual([], witnesses)
        self.assertIn("--ratchets", failures[0])

    def test_block_run_and_non_calls(self):
        text = ("on: push\njobs:\n  lint:\n    runs-on: ubuntu-26.04\n"
                "    steps:\n      - run: |\n          echo run-lint-gates.sh --ratchets\n"
                "          # bash tools/linux/scripts/run-lint-gates.sh . --ratchets\n"
                "          bash tools/linux/scripts/run-lint-gates.sh . --ratchets\n")
        self.assertEqual((1, 0), tuple(map(len, self.check(text))))
        witnesses, failures = self.check(text.replace(" . --ratchets\n", " . --plain\n"))
        self.assertEqual([], witnesses)
        self.assertEqual(1, len(failures))

    def test_disabled_or_nonfatal_call(self):
        base = ("on: push\njobs:\n  lint:\n    uses: Kataglyphis/ANTfrastructure/"
                ".github/workflows/lint-gates.yml@develop\n    with:\n      ratchets: true\n")
        for extra in ("    if: false\n", "    continue-on-error: true\n"):
            witnesses, failures = self.check(base + extra)
            self.assertEqual([], witnesses)
            self.assertEqual(1, len(failures))

    def test_comments_and_untracked_workflow_are_not_calls(self):
        text = "# uses: Kataglyphis/ANTfrastructure/.github/workflows/lint-gates.yml@develop\non: push\njobs: {}\n"
        self.assertEqual(([], []), self.check(text))
        self.assertEqual(([], []), self.check(text, tracked=[]))

    def test_parse_failure_is_fatal(self):
        self.assertEqual(([], []), self.check("on: push\njobs:\n  broken: [\n"))
        broken = ("on: push\njobs:\n  broken: [\n"
                  "  # uses: Kataglyphis/ANTfrastructure/.github/workflows/lint-gates.yml@develop\n")
        self.assertEqual(([], []), self.check(broken))
        _witnesses, failures = self.check(
            broken + "  uses: Kataglyphis/ANTfrastructure/.github/workflows/lint-gates.yml@develop\n")
        self.assertIn("cannot parse tracked workflow with a lint call", failures[0])

    def test_weekly_inventory_folds_a_mutated_call_into_its_verdict(self):
        hub = self.root / "hub"
        consumer = self.root / "consumer"
        (hub / "linux/scripts").mkdir(parents=True)
        (hub / "linux/scripts/called.sh").write_text("#!/usr/bin/env bash\ntrue\n", encoding="utf-8")
        hub_workflow = hub / ".github/workflows/lint-gates.yml"
        hub_workflow.parent.mkdir(parents=True)
        hub_workflow.write_text("on: workflow_call\njobs: {}\n", encoding="utf-8")
        _git(hub)
        workflow = ("on: push\njobs:\n  lint:\n    uses: Kataglyphis/ANTfrastructure/"
                    ".github/workflows/lint-gates.yml@develop\n    with:\n      ratchets: true\n")
        _write(consumer, workflow)
        _git(consumer)
        inventory = self.root / "consumers.json"
        inventory.write_text(json.dumps({
            "hub": {"owner": "Kataglyphis", "repo": "ANTfrastructure",
                    "submodule_path": "third_party/ANTfrastructure"},
            "consumers": [
                {"name": "hub", "clone_url": "unused", "ref": "develop", "self": True},
                {"name": "consumer", "clone_url": "unused", "ref": "develop", "self": False}],
            "entry_point_classes": [
                {"kind": "linux-script", "glob": "linux/scripts/*.sh", "needle": "path"}]
        }), encoding="utf-8")
        report = self.root / "logs/reports/consumer-inventory.md"
        cmd = [sys.executable, str(SCRIPTS / "verify_consumer_inventory.py"),
               "--inventory", str(inventory), "--hub-root", str(hub), "--offline",
               "--local", "hub=%s" % hub, "--local", "consumer=%s" % consumer,
               "--report", str(report)]
        clean = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(0, clean.returncode, clean.stderr)
        self.assertIn("consumer:** OK", report.read_text(encoding="utf-8"))
        _write(consumer, workflow.replace("ratchets: true", "ratchets: false"))
        broken = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(1, broken.returncode)
        self.assertIn("CI quality wiring", broken.stderr)
        self.assertIn("consumer:** FAIL", report.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
