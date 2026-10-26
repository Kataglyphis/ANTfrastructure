"""Input mutations prove fleet reuse reports overlap and refuse incomplete evidence."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from hub_reuse_tests import BASH_BODY, PS_BODY, _git, _write

ROOT = Path(__file__).resolve().parents[3]
SCAN = ROOT / "docs/scripts/verify_fleet_reuse.py"
INVENTORY = ROOT / "linux/scripts/verify_consumer_inventory.py"


class FleetReuseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        base = Path(self.temp.name)
        self.roots = {name: base / name for name in
                      ("ANTfrastructure", "alpha", "beta", "DocumANTation", "fork")}
        for root in self.roots.values():
            root.mkdir()
            _git(root, "init", "-q")
        _write(self.roots["ANTfrastructure"], "scripts/hub.sh", "#!/usr/bin/env bash\ntrue\n")
        _write(self.roots["alpha"], "scripts/alpha.sh", BASH_BODY)
        _write(self.roots["beta"], "scripts/beta.sh",
               BASH_BODY.replace("fetch_asset", "download_item"))
        _write(self.roots["beta"], "scripts/beta.ps1", PS_BODY)
        _write(self.roots["DocumANTation"], "scripts/docs.ps1",
               PS_BODY.replace("Find-Widget", "Get-Gadget"))
        _write(self.roots["fork"], "scripts/fork.sh", BASH_BODY)
        for root in self.roots.values():
            _git(root, "add", "-A")
        self.owned = base / "owned.txt"
        self.owned.write_text("\n".join(f"Kataglyphis/{name}" for name in
                                            self.roots if name != "fork") + "\n",
                              encoding="utf-8")
        self.report = self.roots["ANTfrastructure"] / "logs/reports/fleet-reuse.md"

    def tearDown(self) -> None:
        self.temp.cleanup()

    def scan(self) -> subprocess.CompletedProcess[str]:
        cmd = [sys.executable, str(SCAN), "--hub", str(self.roots["ANTfrastructure"]),
               "--owned-list", str(self.owned), "--report", str(self.report)]
        for name, root in self.roots.items():
            cmd.extend(("--checkout", f"{name}={root}"))
        return subprocess.run(cmd, capture_output=True, text=True,
                              encoding="utf-8", check=False)

    def test_reports_owned_cross_consumer_overlap_without_failing(self) -> None:
        result = self.scan()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        report = self.report.read_text(encoding="utf-8")
        self.assertIn("Active owned nonfork repositories scanned: 4", report)
        self.assertIn("alpha/scripts/alpha.sh:1", report)
        self.assertIn("beta/scripts/beta.sh:1", report)
        self.assertIn("DocumANTation/scripts/docs.ps1:1", report)
        self.assertNotIn("fork/scripts/fork.sh", report)
        self.assertIn("Overlap is a refactoring lead", report)

    def test_mutated_owner_inventory_cannot_silently_narrow_scope(self) -> None:
        self.owned.write_text(self.owned.read_text(encoding="utf-8")
                              + "Kataglyphis/missing-owned-repo\n", encoding="utf-8")
        result = self.scan()
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("has no declared checkout", result.stderr)
        self.assertFalse(self.report.exists())

    def test_mutated_repository_owner_is_refused(self) -> None:
        self.owned.write_text(self.owned.read_text(encoding="utf-8")
                              .replace("Kataglyphis/alpha", "Elsewhere/alpha"),
                              encoding="utf-8")
        result = self.scan()
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("unexpected repository identity", result.stderr)
        self.assertFalse(self.report.exists())

    def test_windows_utf8_bom_inventory_is_supported(self) -> None:
        self.owned.write_text(self.owned.read_text(encoding="utf-8"),
                              encoding="utf-8-sig")
        result = self.scan()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertTrue(self.report.exists())

    def test_local_root_uses_sibling_checkouts_without_another_clone(self) -> None:
        result = subprocess.run(
            [sys.executable, str(SCAN), "--hub", str(self.roots["ANTfrastructure"]),
             "--local-root", str(self.owned.parent), "--owned-list", str(self.owned),
             "--report", str(self.report)],
            capture_output=True, text=True, encoding="utf-8", check=False,
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("DocumANTation/scripts/docs.ps1:1",
                      self.report.read_text(encoding="utf-8"))

    def test_missing_selected_checkout_fails_before_reporting(self) -> None:
        self.roots["beta"] = self.roots["beta"] / "missing"
        result = self.scan()
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("is not a directory", result.stderr)
        self.assertFalse(self.report.exists())

    def test_deleted_tracked_script_fails_before_reporting(self) -> None:
        (self.roots["alpha"] / "scripts/alpha.sh").unlink()
        result = self.scan()
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("tracked file(s) are in the index but not on disk", result.stderr)
        self.assertFalse(self.report.exists())

    def test_report_outside_ignored_logs_is_refused(self) -> None:
        self.report = self.owned.parent / "tracked-report.md"
        result = self.scan()
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("reuse report must be under ignored", result.stderr)
        self.assertFalse(self.report.exists())

    def test_inventory_reuses_its_checkouts_for_the_report(self) -> None:
        specs = [{"name": name, "clone_url": "unused", "ref": "main",
                  "self": name == "ANTfrastructure"} for name in self.roots]
        inventory = self.owned.parent / "consumers.json"
        inventory.write_text(json.dumps({
            "hub": {"owner": "Kataglyphis", "repo": "ANTfrastructure",
                    "submodule_path": "third_party/ANTfrastructure"},
            "consumers": specs,
            "entry_point_classes": [{"kind": "script", "glob": "scripts/*.sh"}],
        }), encoding="utf-8")
        cmd = [sys.executable, str(INVENTORY), "--inventory", str(inventory),
               "--hub-root", str(self.roots["ANTfrastructure"]), "--offline",
               "--owned-list", str(self.owned), "--reuse-report", str(self.report)]
        for name, root in self.roots.items():
            cmd.extend(("--local", f"{name}={root}"))
        result = subprocess.run(cmd, capture_output=True, text=True,
                                encoding="utf-8", check=False)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertTrue(self.report.is_file())
        self.assertIn("alpha/scripts/alpha.sh:1", self.report.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
