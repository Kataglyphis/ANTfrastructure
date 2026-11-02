"""quality-report grades fixture checkouts; it does not prove the scanners' own counts or GitHub lookups."""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import quality_report
import quality_report_compare as compare
from quality_report_model import CODE, HIGHER, LOWER, Item, Metric

GIT_ENV = {"GIT_AUTHOR_NAME": "fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
           "GIT_COMMITTER_NAME": "fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}
BLOCK = """stage_payload() {
  local source="$1" target="$2" mode="$3"
  if [ ! -d "$source" ]; then
    printf 'missing payload %s\\n' "$source" >&2
    return 1
  fi
  mkdir -p "$target" || return 1
  find "$source" -type f -name '*.bin' -print0 | sort -z | xargs -0 -r cp -t "$target"
  case "$mode" in
    strict) sha256sum "$target"/*.bin > "$target/SHA256SUMS" ;;
    loose) : ;;
  esac
  printf 'staged %s into %s for %s\\n' "$source" "$target" "$mode"
}
"""
# Split so this suite is not itself a suppression site.
MARKER = "# shell" + "check disable=SC2034"
JUNIT = ('<?xml version="1.0"?>\n<testsuite>\n  <testcase classname="a" name="one"/>\n'
         '  <testcase classname="a" name="two">\n    <skipped/>\n  </testcase>\n</testsuite>\n')


def git(cwd: Path, *args: str) -> None:
    """One fixture git command; a failure fails the fixture."""
    subprocess.run(["git", "-c", "commit.gpgsign=false", *args], cwd=cwd, check=True,
                   capture_output=True, env={**os.environ, **GIT_ENV})


def repo(base: Path, name: str, files: dict[str, str]) -> Path:
    """A committed fixture checkout."""
    root = base / name
    for rel, body in {".gitignore": "logs/\n", **files}.items():
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_text(body, encoding="utf-8")
    git(root.parent, "init", "-q", str(root))
    git(root, "add", "-A")
    git(root, "commit", "-qm", "fixture")
    return root


def run(root: Path, hub: Path, *extra: str) -> tuple[int, str]:
    """quality_report.main in-process; (exit status, stdout)."""
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = quality_report.main(["--root", str(root), "--hub", str(hub), "--offline", *extra])
    return rc, out.getvalue()


def metric(name: str, value: float, better: str = LOWER,
           members: list[str] | None = None) -> Metric:
    return Metric(name, value, "n", better, CODE, "fixture", members=members)


def record(*metrics: Metric) -> dict[str, dict[str, object]]:
    return {m.name: m.record() for m in metrics}


class Grading(unittest.TestCase):
    def test_rise_regresses(self) -> None:
        result = compare.grade([metric("dupes", 5)], record(metric("dupes", 3)))
        self.assertEqual(result.regressed, [("dupes", "3", "5")])
        self.assertEqual(result.verdict([metric("dupes", 5)]), "regressed")

    def test_fall_improves(self) -> None:
        result = compare.grade([metric("dupes", 3)], record(metric("dupes", 5)))
        self.assertEqual((result.regressed, result.improved), ([], [("dupes", "5", "3")]))

    def test_higher_is_better_falls(self) -> None:
        result = compare.grade([metric("cov", 70.5, HIGHER)], record(metric("cov", 80.0, HIGHER)))
        self.assertEqual(result.regressed, [("cov", "80", "70.5")])

    def test_same_count_set_swap_regresses(self) -> None:
        result = compare.grade([metric("s", 2, members=["a|x|0", "c|x|0"])],
                               record(metric("s", 2, members=["a|x|0", "b|x|0"])))
        self.assertEqual(result.regressed, [("s", "2", "2")])
        self.assertEqual(result.new_members, {"s": ["c|x|0"]})

    def test_failed_collector_is_incomplete(self) -> None:
        broken = Metric("ps", None, "n", LOWER, CODE, "fixture", status="failed", reason="x")
        self.assertEqual(compare.Grade().verdict([broken]), "incomplete")

    def test_empty_queue_says_so(self) -> None:
        text = compare.queue([metric("dupes", 0), metric("cov", 50, HIGHER)], "fixture")
        self.assertIn("No nonzero lower-is-better code metric.", text)

    def test_queue_lists_worst_first(self) -> None:
        busy = metric("dupes", 2)
        busy.items = [Item("a.sh", 3, 1, "small"), Item("b.sh", 9, 7, "large")]
        text = compare.queue([busy], "fixture")
        self.assertLess(text.index("- b.sh:9 large"), text.index("- a.sh:3 small"))


class Checkouts(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="quality-report-"))
        self.hub = repo(self.tmp, "hub", {"tools/hub.sh": "hub_only() {\n  echo hub\n}\n"})

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def measured(self, root: Path) -> dict[str, dict[str, object]]:
        doc = json.loads((root / "logs/code-quality/measurements.json").read_text())
        return doc["metrics"]

    def test_added_duplicate_regresses_and_queues(self) -> None:
        root = repo(self.tmp, "c", {"tools/a.sh": BLOCK})
        rc, _out = run(root, self.hub)
        self.assertEqual(rc, 0)
        shutil.copy(root / "logs/code-quality/measurements.json", self.tmp / "before.json")
        (root / "tools/b.sh").write_text(BLOCK.replace("stage_payload", "copy_payload"))
        git(root, "add", "-A")
        rc, out = run(root, self.hub, "--compare", str(self.tmp / "before.json"))
        self.assertEqual(rc, 1, out)
        self.assertIn("quality-report: verdict=regressed regressed=1", out)
        self.assertIn("REGRESSED duplicated_blocks 0 -> 1", out)
        self.assertRegex((root / "logs/code-quality/queue.md").read_text(), r"- tools/[ab]\.sh:1 ")

    def test_moved_set_member_holds(self) -> None:
        root = repo(self.tmp, "c", {"tools/s.sh": f"#!/usr/bin/env bash\n{MARKER}\nx=1\n"})
        run(root, self.hub)
        shutil.copy(root / "logs/code-quality/measurements.json", self.tmp / "before.json")
        (root / "tools/s.sh").write_text(f"#!/usr/bin/env bash\n\n\n{MARKER}\nx=1\n")
        rc, out = run(root, self.hub, "--compare", str(self.tmp / "before.json"))
        self.assertEqual(rc, 0, out)
        self.assertNotIn("REGRESSED", out)
        (root / "tools/s.sh").write_text(f"#!/usr/bin/env bash\n{MARKER} SC2154\nx=1\n")
        rc, out = run(root, self.hub, "--compare", str(self.tmp / "before.json"))
        self.assertIn("REGRESSED suppressions.shellcheck_disable 1 -> 1", out)

    def test_missing_tree_collector_is_incomplete(self) -> None:
        root = repo(self.tmp, "c", {"tools/x.ps1": "#requires -Version 7.0\nWrite-Output 1\n"})
        bare = self.tmp / "bin"
        bare.mkdir()
        for tool in ("git", "uv"):
            if shutil.which(tool):
                (bare / tool).symlink_to(shutil.which(tool) or "")
        old = os.environ["PATH"]
        os.environ["PATH"] = str(bare)
        try:
            rc, out = run(root, self.hub)
        finally:
            os.environ["PATH"] = old
        self.assertEqual(rc, 2, out)
        self.assertIn("quality-report: verdict=incomplete", out)
        self.assertIn("not-collected: powershell_complexity_findings (pwsh is not on PATH)", out)

    def test_absent_artifact_is_not_collected(self) -> None:
        toml = ('[[artifact]]\nname = "unit"\nkind = "junit"\npath = "out/junit.xml"\n'
                'artifact = "test-reports-*"\n\n'
                '[[artifact]]\nname = "local"\nkind = "junit"\npath = "out/local.xml"\n')
        root = repo(self.tmp, "c", {"quality-report.toml": toml})
        rc, out = run(root, self.hub)
        self.assertEqual(rc, 0, out)
        self.assertIn("not-collected: tests_skipped.unit (", out)
        self.assertIn("not-collected: tests_skipped.local (no file matches out/local.xml)", out)
        self.assertIsNone(self.measured(root)["tests_skipped.unit"]["value"])
        self.assertIsNone(self.measured(root)["tests_passed.local"]["value"])
        (root / "out").mkdir()
        (root / "out/junit.xml").write_text(JUNIT)
        rc, out = run(root, self.hub)
        metrics = self.measured(root)
        self.assertEqual((metrics["tests_passed.unit"]["value"],
                          metrics["tests_skipped.unit"]["value"]), (1, 1))
        self.assertIn("- out/junit.xml:4 a.two", (root / "logs/code-quality/queue.md").read_text())

    def test_agents_drift_is_measured_with_its_rows(self) -> None:
        files = {"AGENTS.md": "# AGENTS.md\n", "l.txt": "", "d/p.md": "# page\n",
                 "quality-report.toml": '[docs]\nbuild_list = "l.txt"\nsource = "d"\n'}
        root = repo(self.tmp, "c", files)
        rc, out = run(root, self.hub)
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.measured(root)["agents_drift_findings"]["value"], 2)
        self.assertIn("- l.txt:1 the docs build list leaves out d/p.md", (root / "logs/code-quality/queue.md").read_text())

    def test_agents_drift_without_agents_md_is_not_collected(self) -> None:
        root = repo(self.tmp, "c", {"tools/a.sh": "a() {\n  :\n}\n"})
        rc, out = run(root, self.hub)
        self.assertEqual(rc, 0, out)
        self.assertIn("not-collected: agents_drift_findings (no AGENTS.md)", out)

    def test_malformed_compare_is_incomplete(self) -> None:
        root = repo(self.tmp, "c", {"tools/a.sh": "a() {\n  :\n}\n"})
        (self.tmp / "bad.json").write_text("{not json")
        rc, out = run(root, self.hub, "--compare", str(self.tmp / "bad.json"))
        self.assertEqual(rc, 2, out)
        self.assertIn("quality-report: verdict=incomplete", out)
        self.assertEqual(out.count("quality-report: verdict="), 1)

    def test_record_carries_every_field(self) -> None:
        root = repo(self.tmp, "c", {"tools/a.sh": "a() {\n  :\n}\n"})
        run(root, self.hub)
        doc = json.loads((root / "logs/code-quality/measurements.json").read_text())
        self.assertTrue({"schema_version", "repo", "sha", "tools", "metrics"} <= set(doc))
        row = doc["metrics"]["duplicated_blocks"]
        self.assertEqual({k: row[k] for k in ("value", "unit", "better", "class")},
                         {"value": 0, "unit": "pairs", "better": "lower", "class": "code"})
        self.assertIn("verify_code_dupes.py", row["source"])
        self.assertIn("No nonzero", (root / "logs/code-quality/queue.md").read_text())


if __name__ == "__main__":
    unittest.main()
