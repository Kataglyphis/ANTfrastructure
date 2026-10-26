"""Mutation proofs for consumer-to-hub Bash and PowerShell function reuse."""

from __future__ import annotations

import importlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
GATE = ROOT / "docs/scripts/verify_hub_reuse.py"
sys.path.insert(0, str(GATE.parent))
reuse = importlib.import_module("verify_hub_reuse")

BASH_BODY = """fetch_asset() {
  local source="$1" target="$2" marker='${'
  if [ ! -f "$source" ]; then
    printf 'missing source %s\\n' "$source" >&2
    return 1
  fi
  mkdir -p "$(dirname "$target")" || return 1
  while IFS= read -r line; do
    if [ -n "$line" ]; then
      printf '%s\\n' "$line" >> "$target"
    fi
  done < "$source"
  printf 'copied %s to %s\\n' "$source" "$target"
}
"""

PS_BODY = """function Find-Widget {
  param([string]$Root, [string]$Mode)
  <# An unbalanced } in a comment must not end the function. #>
  if (-not (Test-Path -LiteralPath $Root)) {
    throw "missing root $Root"
  }
  $found = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter '*.dll' |
    Sort-Object Name)
  foreach ($item in $found) {
    Write-Host "found $($item.FullName) for $Mode"
  }
  if ($found.Count -eq 0) {
    throw "no DLL under $Root"
  }
  return $found
}
"""

SHORT_BODY = """stage_artifact() {
  local source="$1" target="$2" mode="$3"
  [ -d "$source" ] || { printf 'missing source %s\\n' "$source" >&2; return 1; }
  mkdir -p "$target" || return 1
  find "$source" -type f -name '*.dll' -print0 | sort -z | xargs -0 -r cp -t "$target"
  printf 'staged %s into %s for %s\\n' "$source" "$target" "$mode"
}
"""


def _write(root: Path, rel: str, content: str) -> Path:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path


def _git(root: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(root), *args], check=True,
                   capture_output=True, text=True, encoding="utf-8")


class HubReuseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.consumer = Path(self.temp.name) / "consumer"
        self.hub = Path(self.temp.name) / "hub"
        for repo in (self.consumer, self.hub):
            repo.mkdir()
            _git(repo, "init", "-q")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def scan(self, *options: str) -> subprocess.CompletedProcess[str]:
        for repo in (self.consumer, self.hub):
            _git(repo, "add", "-A")
        return subprocess.run(
            [sys.executable, str(GATE), "--root", str(self.consumer),
             "--hub", str(self.hub), *options],
            capture_output=True, text=True, encoding="utf-8", check=False,
        )

    def test_renamed_bash_function_is_a_fatal_finding(self) -> None:
        _write(self.hub, "scripts/shared.sh", BASH_BODY)
        _write(self.consumer, "scripts/local.sh",
               BASH_BODY.replace("fetch_asset", "download_item"))
        result = self.scan()
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("1 overlapping unit pair(s)", result.stdout)
        self.assertIn("consumer/scripts/local.sh:1", result.stdout)
        self.assertIn("hub/scripts/shared.sh:1", result.stdout)
        self.assertEqual(0, self.scan("--report-only").returncode)

    def test_renamed_powershell_function_is_a_fatal_finding(self) -> None:
        _write(self.hub, "windows/Shared.psm1", PS_BODY)
        _write(self.consumer, "scripts/Local.ps1",
               PS_BODY.replace("Find-Widget", "Get-Gadget"))
        result = self.scan()
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("consumer/scripts/Local.ps1:1", result.stdout)
        self.assertIn("hub/windows/Shared.psm1:1", result.stdout)

    def test_thin_hub_delegation_is_clean(self) -> None:
        _write(self.hub, "scripts/shared.sh", BASH_BODY)
        _write(self.consumer, "scripts/local.sh", """fetch_asset() {
  source "${ANTFRASTRUCTURE_DIR}/scripts/shared.sh"
  shared_fetch_asset "$@"
}
""")
        result = self.scan()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("0 overlapping unit pair(s)", result.stdout)

    def test_short_overlap_remains_fatal(self) -> None:
        _write(self.hub, "scripts/shared.sh", SHORT_BODY)
        _write(self.consumer, "scripts/local.sh",
               SHORT_BODY.replace("stage_artifact", "copy_payload"))
        result = self.scan()
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("1 overlapping unit pair(s)", result.stdout)
        self.assertEqual(0, self.scan("--report-only").returncode)

    def test_tracked_generated_archive_name_is_out_of_scope(self) -> None:
        _write(self.hub, "scripts/keeper.sh", "#!/usr/bin/env bash\n")
        _write(self.hub, "scripts/ArchiveReport.sh", BASH_BODY)
        _write(self.consumer, "scripts/ArchiveReport.sh", BASH_BODY)
        result = self.scan()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("0 overlapping unit pair(s)", result.stdout)

    def _declared_copy(self) -> Path:
        assets = ("shared/config/sync-shared-config.sh",
                  "shared/config/shared-assets.manifest",
                  "shared/linux/templates/renovate-git-mode.sh")
        for rel in assets:
            target = self.hub / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / rel, target)
        _write(self.consumer, ".antfrastructure-shared.manifest",
               "renovate-git-mode-sh scripts/lib/renovate-git-mode.sh\n")
        return _write(self.consumer, "scripts/lib/renovate-git-mode.sh",
                      (ROOT / assets[-1]).read_text(encoding="utf-8"))

    def test_declared_synced_bootstrap_is_excluded(self) -> None:
        self._declared_copy()
        result = self.scan()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("1 declared synced copy/copies skipped", result.stdout)
        self.assertIn("0 overlapping unit pair(s)", result.stdout)

    def test_drifted_bootstrap_fails_even_in_report_mode(self) -> None:
        copied = self._declared_copy()
        copied.write_text(copied.read_text(encoding="utf-8") + "# drift\n",
                          encoding="utf-8")
        result = self.scan("--report-only")
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("shared-config check failed", result.stderr)
        self.assertIn("DRIFTED", result.stderr)

    def test_windows_uses_native_powershell_for_copy_drift(self) -> None:
        _write(self.consumer, ".antfrastructure-shared.manifest", "fixture scripts/lib/fixture.sh\n")
        _write(self.hub, "shared/config/Sync-SharedConfig.ps1", "#requires -Version 7.0\n")
        checked = subprocess.CompletedProcess([], 0,
                                              "  OK      scripts/lib/fixture.sh\n", "")
        with (mock.patch.object(reuse.sys, "platform", "win32"),
              mock.patch.object(reuse.shutil, "which", return_value="available"),
              mock.patch.object(reuse.subprocess, "run", return_value=checked) as runner):
            paths = reuse._shared_check(self.consumer, self.hub)
        self.assertEqual({"scripts/lib/fixture.sh"}, paths)
        self.assertEqual("pwsh", runner.call_args.args[0][0])

    def test_hub_self_comparison_skips(self) -> None:
        _write(self.hub, "scripts/shared.sh", BASH_BODY)
        _git(self.hub, "add", "-A")
        result = subprocess.run(
            [sys.executable, str(GATE), "--root", str(self.hub),
             "--hub", str(self.hub), "--report-only"],
            capture_output=True, text=True, encoding="utf-8", check=False,
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("self comparison skipped", result.stdout)

    def test_empty_hub_fails_even_when_consumer_has_no_units(self) -> None:
        _write(self.consumer, "scripts/wrapper.sh", "#!/usr/bin/env bash\n")
        result = self.scan("--report-only")
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("no tracked Bash or PowerShell scripts in hub", result.stderr)


if __name__ == "__main__":
    unittest.main()
