"""fleet-health.py over local Git fixtures and recorded GitHub answers, in one process and offline."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = ROOT / "linux/scripts"
FIXTURES = Path(__file__).resolve().parent / "fixtures/fleet-health"
WORKFLOW = ROOT / ".github/workflows/fleet-health.yml"
sys.path.insert(0, str(SCRIPTS))
_SPEC = importlib.util.spec_from_file_location("fleet_health", SCRIPTS / "fleet-health.py")
assert _SPEC is not None and _SPEC.loader is not None
fleet = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(fleet)

REPOS = ("OrchestrANT", "OxidANT", "AccelerANTgine")
PIN = "1111111111111111111111111111111111111111"
DEIM = "225f612f  deim_dfine_n_coco.onnx  https://example.invalid/deim_dfine_n_coco-v1/deim_dfine_n_coco.onnx\n"
SMOL = "b3853a1c  smollm2_135m_instruct-cpu.tar.xz  https://example.invalid/smollm2-v1/smollm2.tar.xz\n"
LOCKS = {"OrchestrANT": ("resources/models/models.lock", "resources/models/llm.lock"),
         "OxidANT": ("resources/models/models.lock", "resources/models/llm.lock"),
         "AccelerANTgine": ("models/models.lock", "resources/models/llm.lock")}
ALL = ",".join(REPOS)


def git(path: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(path), *args], check=True, capture_output=True,
                          text=True).stdout.strip()


class FleetHealthTests(unittest.TestCase):
    base: Path
    tmp: tempfile.TemporaryDirectory[str]
    env: dict[str, str]

    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = tempfile.TemporaryDirectory()
        cls.base = Path(cls.tmp.name)
        cls.env = dict(os.environ)
        os.environ.update({"HOME": str(cls.base), "GIT_CONFIG_NOSYSTEM": "1",
                           "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
                           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid",
                           "FAKE_MEASUREMENTS": str(cls.base / "meas"), "GH_TOKEN": "recorded"})
        for key in ("FLEET_HEALTH_TOKEN", "GITHUB_TOKEN", "GITHUB_RUN_ID"):
            os.environ.pop(key, None)
        (cls.base / "meas").mkdir()
        for repo in REPOS:
            cls.make_repo(repo)
        cls.reset_measurements()
        cls.baseline1 = cls.record_baseline("OrchestrANT", "b1")
        cls.baseline3 = cls.record_baseline(ALL, "b3")

    @classmethod
    def tearDownClass(cls) -> None:
        os.environ.clear()
        os.environ.update(cls.env)
        cls.tmp.cleanup()

    @classmethod
    def make_repo(cls, repo: str) -> None:
        origin, co = cls.base / "origins" / f"{repo}.git", cls.base / "root" / repo
        subprocess.run(["git", "init", "-q", "--bare", "-b", "develop", str(origin)], check=True)
        subprocess.run(["git", "init", "-q", "-b", "develop", str(co)], check=True)
        (co / "scripts/linux").mkdir(parents=True)
        shutil.copy(FIXTURES / "quality-report.sh", co / "scripts/linux/quality-report.sh")
        shutil.copy(FIXTURES / "quality-report.toml", co / "quality-report.toml")
        (co / ".gitignore").write_text("logs/\n")
        (co / "README.md").write_text("fixture\n")
        models, llm = LOCKS[repo]
        for rel, body in ((models, "# sha256 file url\n" + DEIM), (llm, SMOL)):
            (co / rel).parent.mkdir(parents=True, exist_ok=True)
            (co / rel).write_text(body)
        git(co, "add", "-A")
        git(co, "update-index", "--add", "--cacheinfo", f"160000,{PIN},third_party/ANTfrastructure")
        (co / "third_party/ANTfrastructure").mkdir(parents=True)
        git(co, "commit", "-q", "-m", "fixture")
        git(co, "remote", "add", "origin", str(origin))
        git(co, "push", "-q", "origin", "develop")

    @classmethod
    def reset_measurements(cls, change: Any = None) -> None:
        template = (FIXTURES / "measurements.json").read_text()
        for repo in REPOS:
            doc = json.loads(template.replace("@REPO@", repo))
            if change and repo == "OrchestrANT":
                change(doc["metrics"])
            (cls.base / "meas" / f"{repo}.json").write_text(json.dumps(doc))

    @classmethod
    def replay(cls, change: Any = None) -> str:
        answers = json.loads((FIXTURES / "replay-hub.json").read_text())
        template = (FIXTURES / "replay-repo.json").read_text()
        for repo in REPOS:
            sha = git(cls.base / "root" / repo, "rev-parse", "HEAD")
            answers.update(json.loads(template.replace("@REPO@", repo).replace("@SHA@", sha)
                                      .replace("@PIN@", PIN)))
        if change:
            change(answers)
        path = cls.base / "replay.json"
        path.write_text(json.dumps(answers))
        return str(path)

    @classmethod
    def run_main(cls, *args: str, change: Any = None, out: str = "out") -> tuple[int, str, dict[str, Any]]:
        argv = ["--local-root", str(cls.base / "root"), "--out", str(cls.base / out),
                "--now", "2026-11-02T09:00:00Z", "--replay", cls.replay(change), *args]
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = fleet.main(argv)
        path = cls.base / out / "2026-11-02.json"
        record = json.loads(path.read_text()) if path.exists() else {}
        return rc, buf.getvalue(), record

    @classmethod
    def record_baseline(cls, repos: str, name: str) -> str:
        rc, out, _ = cls.run_main("--repos", repos, out=name)
        assert rc == 0, out
        return str(cls.base / name / "2026-11-02.json")

    def setUp(self) -> None:
        for key in ("FLEET_HEALTH_TOKEN", "GITHUB_TOKEN", "GITHUB_RUN_ID"):
            os.environ.pop(key, None)
        os.environ["GH_TOKEN"] = "recorded"
        self.reset_measurements()

    def metric(self, record: dict[str, Any], repo: str, name: str) -> dict[str, Any]:
        return record["repos"][repo]["metrics"][name]

    def test_held_against_an_unchanged_baseline(self) -> None:
        rc, out, record = self.run_main("--repos", "OrchestrANT", "--compare", self.baseline1)
        self.assertEqual(rc, 0, out)
        self.assertIn("fleet-health: verdict=ok regressed=0 improved=0 metrics=", out)
        self.assertEqual(self.metric(record, "OrchestrANT", "ruff_findings")["grade"], "held")
        self.assertEqual(self.metric(record, "OrchestrANT", "suppressions.no_qa")["grade"], "held")
        self.assertEqual(self.metric(record, "OrchestrANT", "ci.linux-x64.yml.median_minutes")["value"], 29.0)

    def test_a_new_suppression_site_regresses(self) -> None:
        def add(metrics: dict[str, Any]) -> None:
            metrics["suppressions.no_qa"].update(value=2, members=[
                "src/a.py|import os  # noqa: F401|0", "src/b.py|x = 1  # noqa: E501|0"])
        self.reset_measurements(add)
        rc, out, record = self.run_main("--repos", "OrchestrANT", "--compare", self.baseline1)
        self.assertEqual(rc, 1, out)
        self.assertIn("REGRESSED OrchestrANT/suppressions.no_qa 1 -> 2", out)
        self.assertIn("fleet-health: verdict=regressed regressed=1 ", out)
        self.assertEqual(record["regressed"][0]["metric"], "suppressions.no_qa")

    def test_fewer_findings_improve(self) -> None:
        self.reset_measurements(lambda m: m["ruff_findings"].update(value=1))
        rc, out, record = self.run_main("--repos", "OrchestrANT", "--compare", self.baseline1)
        self.assertEqual(rc, 0, out)
        self.assertIn("verdict=ok regressed=0 improved=1 ", out)
        self.assertEqual(self.metric(record, "OrchestrANT", "ruff_findings")["grade"], "improved")

    def test_an_external_metric_moves_and_is_never_graded(self) -> None:
        def worse(answers: dict[str, Any]) -> None:
            for row in answers["/repos/Kataglyphis/OrchestrANT/actions/workflows/11/runs"
                               "?branch=develop&status=completed&per_page=100"]["workflow_runs"]:
                row["conclusion"] = "failure"
            answers["/repos/Kataglyphis/ANTfrastructure/compare/" + PIN + "...develop"]["ahead_by"] = 70
        self.reset_measurements(lambda m: m["agents_md_lines"].update(value=900))
        rc, out, record = self.run_main("--repos", "OrchestrANT", "--compare", self.baseline1, change=worse)
        self.assertEqual(rc, 0, out)
        rate = self.metric(record, "OrchestrANT", "ci.linux-x64.yml.success_rate")
        self.assertEqual((rate["before"], rate["value"], rate["grade"]), (75.0, 0.0, "moved"))
        self.assertEqual(self.metric(record, "OrchestrANT", "hub_pin.lag_commits")["grade"], "moved")
        self.assertEqual(self.metric(record, "OrchestrANT", "agents_md_lines")["grade"], "moved")
        self.assertNotIn("REGRESSED", out)

    def test_a_first_run_has_no_previous_artifact(self) -> None:
        rc, out, record = self.run_main("--repos", "OrchestrANT", "--compare", "previous-run")
        self.assertEqual(rc, 0, out)
        self.assertIn("compare: none (no successful fleet-health.yml run carries fleet-health-json yet)", out)
        self.assertEqual(self.metric(record, "OrchestrANT", "ruff_findings")["grade"], "new")

    def test_the_previous_run_artifact_is_the_baseline(self) -> None:
        def previous(answers: dict[str, Any]) -> None:
            answers["/repos/Kataglyphis/ANTfrastructure/actions/artifacts?name=fleet-health-json&per_page=100"] = {
                "artifacts": [{"id": 801, "name": "fleet-health-json", "expired": False, "created_at": "2026-10-26T09:30:00Z",
                               "workflow_run": {"id": 9301, "head_branch": "develop"}}]}
            answers["/repos/Kataglyphis/ANTfrastructure/actions/runs/9301"] = {"id": 9301, "conclusion": "success"}
            answers["ARTIFACT Kataglyphis/ANTfrastructure 801"] = {
                "2026-10-26.json": json.loads(Path(self.baseline1).read_text())}
        self.reset_measurements(lambda m: m["ruff_findings"].update(value=4))
        rc, out, _ = self.run_main("--repos", "OrchestrANT", "--compare", "previous-run", change=previous)
        self.assertEqual(rc, 1, out)
        self.assertIn("compare: fleet-health-json of run 9301", out)
        self.assertIn("REGRESSED OrchestrANT/ruff_findings 3 -> 4", out)

    def test_a_missing_token_leaves_alerts_not_collected(self) -> None:
        fake = self.base / "nogh"
        fake.mkdir(exist_ok=True)
        (fake / "gh").write_text("#!/bin/sh\nexit 1\n")
        (fake / "gh").chmod(0o755)
        del os.environ["GH_TOKEN"]
        path = os.environ["PATH"]
        os.environ["PATH"] = f"{fake}:{path}"
        try:
            rc, out, record = self.run_main("--repos", "OrchestrANT", "--compare", self.baseline1)
        finally:
            os.environ["PATH"] = path
        self.assertEqual(rc, 0, out)
        self.assertIn("not-collected: OrchestrANT/dependabot.open.high (no token: set FLEET_HEALTH_TOKEN", out)
        self.assertIn("not-collected: OrchestrANT/secret_scanning.open (no token", out)
        self.assertEqual(self.metric(record, "OrchestrANT", "code_scanning.open.high")["grade"], "not-collected")

    def test_a_403_is_not_collected_and_never_held(self) -> None:
        def refuse(answers: dict[str, Any]) -> None:
            answers["/repos/Kataglyphis/OrchestrANT/dependabot/alerts?state=open&per_page=100"] = {
                "http_errors": [403], "answer": []}
        rc, out, record = self.run_main("--repos", "OrchestrANT", "--compare", self.baseline1, change=refuse)
        self.assertEqual(rc, 0, out)
        self.assertIn("not-collected: OrchestrANT/dependabot.high_critical_ids (HTTP 403 for", out)
        self.assertEqual(self.metric(record, "OrchestrANT", "dependabot.high_critical_ids")["grade"], "not-collected")
        self.assertEqual(self.metric(record, "OrchestrANT", "code_scanning.open.high")["value"], 1)

    def test_a_missing_checkout_is_incomplete(self) -> None:
        rc, out, _ = self.run_main("--repos", "OrchestrANT,NoSuchRepo", "--compare", self.baseline1)
        self.assertEqual(rc, 2, out)
        self.assertIn("fleet-health: verdict=incomplete ", out)
        self.assertIn("failed: NoSuchRepo/checkout (missing checkout:", out)

    def test_a_dirty_checkout_is_refused(self) -> None:
        readme = self.base / "root/OrchestrANT/README.md"
        readme.write_text("edited\n")
        try:
            rc, out, record = self.run_main("--repos", "OrchestrANT", "--compare", self.baseline1)
        finally:
            readme.write_text("fixture\n")
        self.assertEqual(rc, 2, out)
        self.assertIn("failed: OrchestrANT/checkout (dirty checkout:", out)
        self.assertEqual(list(record["repos"]["OrchestrANT"]["metrics"]), ["checkout"])

    def test_a_checkout_behind_origin_develop_is_refused(self) -> None:
        other = self.base / "other"
        subprocess.run(["git", "clone", "-q", str(self.base / "origins/OxidANT.git"), str(other)], check=True)
        git(other, "commit", "-q", "--allow-empty", "-m", "ahead")
        git(other, "push", "-q", "origin", "develop")
        try:
            rc, out, _ = self.run_main("--repos", "OxidANT", "--compare", self.baseline3)
        finally:
            git(other, "push", "-q", "-f", "origin", "HEAD~1:develop")
            shutil.rmtree(other)
        self.assertEqual(rc, 2, out)
        self.assertIn("failed: OxidANT/checkout (stale checkout:", out)
        self.assertIn("1 commit(s) behind origin/develop", out)

    def change_lock(self, repo: str, index: int, body: str) -> None:
        co = self.base / "root" / repo
        rel = LOCKS[repo][index]
        if body:
            (co / rel).write_text(body)
        else:
            git(co, "rm", "-q", rel)
        git(co, "commit", "-q", "-am", "drift")

    def undo_lock(self, repo: str) -> None:
        git(self.base / "root" / repo, "reset", "-q", "--hard", "origin/develop")

    def test_models_lock_drift_regresses_the_shared_facts(self) -> None:
        self.change_lock("AccelerANTgine", 0, DEIM.replace("225f612f", "deadbeef"))
        try:
            rc, out, record = self.run_main("--repos", ALL, "--compare", self.baseline3)
        finally:
            self.undo_lock("AccelerANTgine")
        self.assertEqual(rc, 1, out)
        self.assertIn("REGRESSED fleet/shared_facts.models_lock_deim 0 -> 1", out)
        detail = record["repos"]["fleet"]["metrics"]["shared_facts.models_lock_deim"]["detail"]
        self.assertTrue(detail["AccelerANTgine"][0].startswith("deadbeef"))

    def test_llm_lock_drift_regresses_and_an_absent_lock_is_not_collected(self) -> None:
        self.change_lock("OxidANT", 1, SMOL.replace("smollm2-v1", "smollm2-v2"))
        try:
            rc, out, _ = self.run_main("--repos", ALL, "--compare", self.baseline3)
        finally:
            self.undo_lock("OxidANT")
        self.assertEqual(rc, 1, out)
        self.assertIn("REGRESSED fleet/shared_facts.llm_lock_smollm2 0 -> 1", out)
        self.change_lock("AccelerANTgine", 1, "")
        try:
            rc, out, _ = self.run_main("--repos", ALL, "--compare", self.baseline3)
        finally:
            self.undo_lock("AccelerANTgine")
        self.assertEqual(rc, 0, out)
        self.assertIn("not-collected: fleet/shared_facts.llm_lock_smollm2 (llm.lock absent in AccelerANTgine;"
                      " present in OxidANT (1 rows), OrchestrANT (1 rows))", out)

    def test_a_5xx_that_never_recovers_is_incomplete_and_regressions_still_print(self) -> None:
        def broken(answers: dict[str, Any]) -> None:
            answers["/repos/Kataglyphis/OrchestrANT/actions/workflows?per_page=100"] = {
                "http_errors": [502, 502, 502, 502, 502], "answer": {"workflows": []}}
        self.reset_measurements(lambda m: m["ruff_findings"].update(value=5))
        rc, out, _ = self.run_main("--repos", "OrchestrANT", "--compare", self.baseline1, change=broken)
        self.assertEqual(rc, 2, out)
        self.assertIn("fleet-health: verdict=incomplete regressed=1 ", out)
        self.assertIn("failed: OrchestrANT/ci (HTTP 502 for /repos/Kataglyphis/OrchestrANT/actions/workflows", out)
        self.assertIn("REGRESSED OrchestrANT/ruff_findings 3 -> 5", out)

    def test_a_5xx_that_recovers_within_the_retry_is_collected(self) -> None:
        def flaky(answers: dict[str, Any]) -> None:
            key = "/repos/Kataglyphis/OrchestrANT/code-scanning/analyses?per_page=1"
            answers[key] = {"http_errors": [503, 503], "answer": answers[key]}
        rc, out, record = self.run_main("--repos", "OrchestrANT", "--compare", self.baseline1, change=flaky)
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.metric(record, "OrchestrANT", "code_scanning.days_since_analysis")["value"], 4.0)

    def test_a_new_high_advisory_id_regresses(self) -> None:
        def advisory(answers: dict[str, Any]) -> None:
            findings = answers["ARTIFACT Kataglyphis/OrchestrANT 501"]["security-audit.json"]["findings"]
            findings.append({"id": "GHSA-new0-new0-new0", "severity": "CRITICAL", "package": "x@1", "lockfile": "uv.lock"})
        rc, out, _ = self.run_main("--repos", "OrchestrANT", "--compare", self.baseline1, change=advisory)
        self.assertEqual(rc, 1, out)
        self.assertIn("REGRESSED OrchestrANT/security_audit.high_critical_ids 1 -> 2", out)

    def test_artifact_metrics_come_from_the_same_sha_record(self) -> None:
        rc, out, record = self.run_main("--repos", "OrchestrANT")
        self.assertEqual(rc, 0, out)
        row = self.metric(record, "OrchestrANT", "tests_passed.linux-x64")
        self.assertEqual((row["value"], row["status"]), (120, "collected"))
        self.assertIn("artifact of run 9101", row["source"])

        def elsewhere(answers: dict[str, Any]) -> None:
            key = "/repos/Kataglyphis/OrchestrANT/actions/artifacts?name=code-quality-measurements&per_page=100"
            answers[key]["artifacts"][0]["workflow_run"]["head_sha"] = "0" * 40
        rc, out, record = self.run_main("--repos", "OrchestrANT", change=elsewhere)
        self.assertIn("not-collected: OrchestrANT/tests_passed.linux-x64 (no run at ", out)
        self.assertEqual(self.metric(record, "OrchestrANT", "bench_history.bench-history-k.verdict")["value"], "ok")
        self.assertEqual(self.metric(record, "OrchestrANT", "develop_red.open_issues")["value"], 1)
        self.assertEqual(self.metric(record, "OrchestrANT", "code_scanning.open_on_absent_paths")["value"], 1)

    def sync(self, record: dict[str, Any], issues: list[dict[str, Any]]) -> str:
        path = self.base / "record.json"
        path.write_text(json.dumps(record))
        answers = {"/repos/Kataglyphis/ANTfrastructure/issues?labels=fleet-health&state=open&per_page=100": issues,
                   "/repos/Kataglyphis/ANTfrastructure/labels/fleet-health": {"http_errors": [404], "answer": None}}
        replay = self.base / "issue-replay.json"
        replay.write_text(json.dumps(answers))
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self.assertEqual(fleet.main(["--sync-issue", str(path), "--replay", str(replay)]), 0)
        return buf.getvalue()

    def test_the_issue_opens_updates_and_closes(self) -> None:
        record = json.loads(Path(self.baseline1).read_text())
        regressed = {**record, "verdict": "regressed",
                     "regressed": [{"repo": "OxidANT", "metric": "unsafe_blocks", "before": "34", "now": "35"}]}
        out = self.sync(regressed, [])
        self.assertIn('dry-run: POST /repos/Kataglyphis/ANTfrastructure/issues {"body":', out)
        self.assertIn('"labels": ["fleet-health"]', out)
        self.assertIn("`OxidANT/unsafe_blocks`: 34 -> 35", out)
        self.assertNotIn("develop-red", out)
        out = self.sync(regressed, [{"number": 5, "state": "open"}, {"number": 9, "state": "open"}])
        self.assertIn("dry-run: PATCH /repos/Kataglyphis/ANTfrastructure/issues/5 {\"body\"", out)
        self.assertIn("dry-run: PATCH /repos/Kataglyphis/ANTfrastructure/issues/9 {\"state\": \"closed\"", out)
        self.assertNotIn("POST /repos/Kataglyphis/ANTfrastructure/issues {", out)
        out = self.sync({**record, "verdict": "ok"}, [{"number": 5, "state": "open"}])
        self.assertIn('dry-run: PATCH /repos/Kataglyphis/ANTfrastructure/issues/5 {"state": "closed"', out)
        out = self.sync({**record, "verdict": "incomplete"}, [{"number": 5, "state": "open"}])
        self.assertIn("fleet-health issue: left alone: verdict incomplete", out)
        self.assertNotIn("dry-run:", out)

    def test_a_malformed_compare_file_is_incomplete(self) -> None:
        bad = self.base / "bad.json"
        bad.write_text(json.dumps({"schema_version": 1, "kind": "something-else"}))
        rc, out, _ = self.run_main("--repos", "OrchestrANT", "--compare", str(bad))
        self.assertEqual(rc, 2, out)
        self.assertIn("is not a schema_version 1 fleet-health record", out)

    def test_the_workflow_runs_weekly_and_fails_only_on_exit_2(self) -> None:
        text = WORKFLOW.read_text()
        for needle in ("- cron: '0 9 * * 1'", "workflow_dispatch:", "name: fleet-health-json",
                       "retention-days: 90", "secrets.FLEET_HEALTH_TOKEN", "--clone --compare previous-run",
                       "--sync-issue", "GITHUB_STEP_SUMMARY", "issues: write"):
            self.assertIn(needle, text)
        self.assertIn("1) grep -q '^fleet-health: verdict=regressed '", text)
        self.assertNotIn("develop-red", text)


if __name__ == "__main__":
    unittest.main(verbosity=1)
