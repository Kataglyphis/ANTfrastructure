"""Exercise source proof and owned-unit failures with fixtures; no live GitHub, daemon, image or GPU is contacted."""

import argparse
import copy
import hashlib
import json
import runpy
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from typing import Any
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from source_ci import combined, dispatch, fetch, linux, windows
from source_ci.common import WORKFLOWS, dispatch_record, read, save

seal = runpy.run_path(str(SCRIPTS / "seal-mutation-unit.py"))
# The hub workflow's mutation jobs; the auditor reads the count from the workflow at the tested head.
SHARDS = 9


class SourceFixtures(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.head = "b" * 40
        self.plan: dict[str, Any] = {"source_revision": self.head, "branch": "feature/test", "workflows": [
            {"file": workflow, "run_id": index} for index, workflow in enumerate(WORKFLOWS, 1)]}
        self.write("dispatch.json", self.plan)
        self.write("binding.json", {"head": self.head, "merge_checkout": self.head, "tree": "c" * 40,
                                    "head_merge_and_local_tree_match": True})
        for row in self.plan["workflows"]:
            self.plant_run(row)
        self.manifest = [{"id": f"test.{index}"} for index in range(SHARDS)]
        self.summary = {"Total": 20, "Passed": 20, "MinTests": 10, "ExitCode": 0, "PesterFailures": 0,
                        "FailedCount": 0, "FloorMet": True, "CoverageFloorMet": True, "Failed": [], "Skipped": [],
                        "Broken": [], "CoverageFailures": [], "Coverage": [{"Module": "Example.psm1", "Analyzed": 10,
                        "Executed": 9, "Percent": 90, "MinimumPercent": 80, "ReportPath": r"C:\test\coverage.xml"}]}
        self.xml = '<coverage lines-valid="10" lines-covered="9" line-rate="0.9"><class filename="Example.psm1"/></coverage>'
        self.archive()
        self.write("prior.json", {"head": "a" * 40, "coverage": [{"module": "Example.psm1", "minimum_percent": 80}]})
        self.enterContext(patch.object(linux, "git", side_effect=self.git))
        self.enterContext(patch.object(windows, "git", return_value=b"unchanged coverage policy"))
        self.args = argparse.Namespace(root=self.root, head=self.head, run=self.root / "run-1.json", jobs=self.root / "jobs-1.json",
            tree_binding=self.root / "binding.json", log_dir=self.root, directory=self.root, dispatch=self.root / "dispatch.json",
            output=self.root / "proof.json", zip=self.root / "windows-artifact.zip", api=self.root / "api.json",
            prior_proof=self.root / "prior.json", linux=self.root / "linux.json", windows=self.root / "windows.json")

    def write(self, name: str, value: Any) -> None:
        (self.root / name).write_text(json.dumps(value), encoding="utf-8")

    def plant_run(self, row: dict[str, Any]) -> None:
        index = row["run_id"]
        self.write(f"run-{index}.json", {"id": index, "head_sha": self.head, "head_branch": self.plan["branch"],
            "event": "workflow_dispatch", "status": "completed", "conclusion": "success", "run_attempt": 1,
            "path": ".github/workflows/" + row["file"], "name": row["file"]})
        names = ["source tests"]
        if index == 1:
            names = ["preflight", "submodule-cycles", *(f"mutations ({number})" for number in range(SHARDS))]
        if index == 3:
            names.append("docs / Publish the site")
        jobs = []
        for number, name in enumerate(names):
            job_id = index * 100 + number
            jobs.append({"id": job_id, "run_id": index, "head_sha": self.head, "name": name,
                         "status": "completed", "conclusion": "skipped" if name.startswith("docs /") else "success"})
            text = self.head + "\nsource assertions passed\n"
            if name == "preflight":
                text += "All preflight checks passed.\nAll linux script test suites passed (2 suites, 30 assertions)\n"
            if name.startswith("mutations ("):
                text += (f"stamp [1/1] bites test.{number - 2} caught\n"
                         f"coverage: proved 1 of 1 selected; 0 delegated to CI, 0 skipped by this host; the manifest holds {SHARDS}\n")
            if index == 5:
                text += "security-audit: fixture mode gate\n"
            (self.root / f"source-ci-{job_id}.log").write_text(text, encoding="utf-8")
        self.write(f"jobs-{index}.json", {"total_count": len(jobs), "jobs": jobs})

    def archive(self) -> None:
        target = self.root / "windows-artifact.zip"
        with zipfile.ZipFile(target, "w") as archive:
            archive.writestr("summary-test.json", json.dumps(self.summary))
            archive.writestr("coverage.xml", self.xml)
        self.write("api.json", {"id": 99, "workflow_run": {"id": 2, "head_sha": self.head}, "expired": False,
                   "digest": "sha256:" + hashlib.sha256(target.read_bytes()).hexdigest(), "size_in_bytes": target.stat().st_size})

    def git(self, _root: Path, command: str, selection: str) -> bytes:
        if command == "show" and selection.endswith(".github/workflows/linux-x64.yml"):
            return f"    strategy:\n      matrix:\n        shard: [{', '.join(map(str, range(SHARDS)))}]\n".encode()
        return json.dumps(self.manifest).encode() if command == "show" else ("c" * 40).encode()

    def audit(self) -> None:
        self.args.output = self.args.linux
        linux.run(self.args)
        self.args.output = self.args.windows
        windows.run(self.args)
        self.args.output = self.root / "combined.json"
        combined.run(self.args)

    def test_complete_proofs_and_no_overwrite(self) -> None:
        self.audit()
        result = read(self.args.output)
        self.assertEqual((result["linux_unique_mutations"], result["native_windows_tests"], len(result["runs"])), (SHARDS, 20, 5))
        with self.assertRaises(FileExistsError):
            combined.run(self.args)

    def test_linux_mutation_union_and_nonvacuous_reports(self) -> None:
        target = self.root / "source-ci-102.log"
        original = target.read_text()
        for old, new in [("test.0", "test.1"), ("bites", "missed"), ("0 delegated", "1 delegated"),
                         ("0 skipped", "1 skipped"), ("proved 1", "proved 0"), (self.head, "wrong-checkout")]:
            target.write_text(original.replace(old, new))
            with self.subTest(new=new), self.assertRaises(ValueError):
                linux.run(self.args)
        target.write_text(original)
        self.manifest.append(self.manifest[0])
        with self.assertRaises(ValueError):
            linux.run(self.args)

    def test_linux_job_and_tree_identity(self) -> None:
        path = self.args.jobs
        original = read(path)
        for key, value in [("conclusion", "failure"), ("head_sha", "a" * 40), ("run_id", 8), ("status", "in_progress")]:
            jobs = copy.deepcopy(original)
            jobs["jobs"][0][key] = value
            self.write(path.name, jobs)
            with self.subTest(key=key), self.assertRaises(ValueError):
                linux.run(self.args)
        self.write(path.name, original)
        binding = read(self.args.tree_binding)
        self.write("binding.json", {**binding, "tree": "d" * 40})
        with self.assertRaises(ValueError):
            linux.run(self.args)

    def test_windows_verdict_policy_and_digest(self) -> None:
        original = copy.deepcopy(self.summary)
        for key, value in [("Total", 21), ("Passed", 0), ("ExitCode", 2), ("FloorMet", False),
                           ("CoverageFloorMet", False), ("Skipped", ["hidden"]), ("Broken", ["broken"])]:
            self.summary = {**original, key: value}
            self.archive()
            with self.subTest(key=key), self.assertRaises(ValueError):
                windows.run(self.args)
        self.summary = original
        self.xml = self.xml.replace('lines-covered="9"', 'lines-covered="0"')
        self.archive()
        with self.assertRaises(ValueError):
            windows.run(self.args)
        self.xml = self.xml.replace('lines-covered="0"', 'lines-covered="9"')
        self.archive()
        with patch.object(windows, "git", side_effect=[b"old", b"new"]), self.assertRaises(ValueError):
            windows.run(self.args)
        (self.root / "windows-artifact.zip").write_bytes((self.root / "windows-artifact.zip").read_bytes() + b"added suffix")
        with self.assertRaises(ValueError):
            windows.run(self.args)

    def test_combined_rejects_changed_logs_runs_and_skips(self) -> None:
        self.audit()
        self.args.output.unlink()
        self.args.output = self.root / "combined.json"
        target = self.root / "source-ci-500.log"
        original = target.read_text()
        target.write_text(original.replace("mode gate", "mode report"))
        with self.assertRaises(ValueError):
            combined.run(self.args)
        target.write_text(original)
        jobs = read(self.root / "jobs-4.json")
        extra = {**jobs["jobs"][0], "id": 401, "name": "an executed sibling"}
        (self.root / "source-ci-401.log").write_text("executed sibling\n")
        jobs["jobs"][0]["conclusion"] = "skipped"
        jobs["jobs"].append(extra)
        jobs["total_count"] = 2
        self.write("jobs-4.json", jobs)
        with self.assertRaises(ValueError):
            combined.run(self.args)
        self.plant_run(self.plan["workflows"][3])
        path = self.root / "source-ci-102.log"
        path.write_text(path.read_text() + "changed\n")
        with self.assertRaises(ValueError):
            combined.run(self.args)

    def test_combined_rejects_wrong_workflow_and_event(self) -> None:
        self.audit()
        self.args.output.unlink()
        path = self.root / "run-4.json"
        original = read(path)
        for key, value in [("event", "pull_request"), ("head_branch", "different"), ("path", ".github/workflows/other.yml")]:
            self.write(path.name, {**original, key: value})
            with self.subTest(key=key), self.assertRaises(ValueError):
                combined.run(self.args)

    def test_dispatch_record_requires_complete_distinct_runs(self) -> None:
        for rows in [self.plan["workflows"][:-1], [self.plan["workflows"][0]] * 5,
                     [*self.plan["workflows"][:-1], {"file": "security-audit.yml", "run_id": 1}]]:
            self.write("dispatch.json", {**self.plan, "workflows": rows})
            with self.assertRaises(ValueError):
                dispatch_record(self.args.dispatch)

    def test_dispatch_once_records_ambiguous_write_before_raising(self) -> None:
        args = argparse.Namespace(repo="example/hub", head=self.head, branch="feature/test", output=self.root / "new-dispatch.json")
        api = lambda *argv: {"object": {"sha": self.head}} if argv[0] == "api" else []
        sent: list[list[str]] = []

        def send(argv: list[str], **_kwargs: Any) -> str:
            recorded = read(args.output)
            self.assertEqual(recorded["workflows"][-1]["state"], "dispatching-once-do-not-repeat-if-interrupted")
            sent.append(argv)
            return "request accepted without run URL"

        with patch.object(dispatch, "gh", side_effect=api), patch.object(dispatch, "checked_output", side_effect=send):
            with self.assertRaises(ValueError):
                dispatch.run(args)
            with self.assertRaises(FileExistsError):
                dispatch.run(args)
        self.assertEqual(len(sent), 1)
        self.assertIn("unresolved", read(args.output)["workflows"][0]["state"])

    def test_dispatch_reuses_existing_runs_without_writes(self) -> None:
        args = argparse.Namespace(repo="example/hub", head=self.head, branch="feature/test", output=self.root / "reuse.json")

        def api(*argv: str) -> Any:
            if argv[0] == "api":
                return {"object": {"sha": self.head}}
            workflow = argv[argv.index("--workflow") + 1]
            return [{"headSha": self.head, "headBranch": args.branch, "databaseId": WORKFLOWS.index(workflow) + 1}]

        with patch.object(dispatch, "gh", side_effect=api), patch.object(dispatch, "checked_output") as send:
            dispatch.run(args)
            send.assert_not_called()
        self.assertEqual(len(dispatch_record(args.output)["workflows"]), 5)

    def test_failed_raw_fetch_preserves_no_http_error_body(self) -> None:
        path = self.root / "download.log"
        failure = subprocess.CalledProcessError(1, ["gh"], output=b'{"message":"503"}')
        def request(_argv: list[str], **kwargs: Any) -> subprocess.CompletedProcess:
            if kwargs.get("check"):
                raise failure
            return subprocess.CompletedProcess(["gh"], 1, failure.output, b"503")

        with patch.object(fetch.subprocess, "run", side_effect=request), self.assertRaises(subprocess.CalledProcessError):
            fetch.fetch("example/hub", "actions/jobs/1/logs", path, raw=True)
        self.assertFalse(path.exists())
        self.assertFalse(path.with_name(path.name + ".download").exists())
        path.write_bytes(b"preserved")
        with patch.object(fetch.subprocess, "run") as remote:
            fetch.fetch("example/hub", "unused", path, raw=True)
            remote.assert_not_called()
        self.assertEqual(path.read_bytes(), b"preserved")


class UnitSealTests(unittest.TestCase):
    def test_exact_ids_and_terminal_unit_before_stop(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest, log = root / "manifest.json", root / "mutation.log"
            save(manifest, [{"id": "a"}])
            log.write_text("[1/1] bites a caught\ncoverage: proved 1 of 1: the whole manifest\nOK: every recorded mutation is caught by its tests\n")
            args = argparse.Namespace(unit="fixture.service", manifest=manifest, log=log, output=root / "proof.json", selected=False)
            good = {"Id": args.unit, "LoadState": "loaded", "ActiveState": "active", "SubState": "exited", "MainPID": "0",
                    "ExecMainStatus": "0", "Result": "success", "ExecMainExitTimestampMonotonic": "123"}
            namespace = seal["run"].__globals__
            for key, value in [("LoadState", "not-found"), ("MainPID", "4"), ("ExecMainStatus", "9"),
                               ("SubState", "running"), ("ExecMainExitTimestampMonotonic", "0")]:
                with (patch.dict(namespace, unit_state=lambda _unit, key=key, value=value: {**good, key: value},
                                 checked_output=lambda *_args: self.fail("unsafe stop")),
                      self.subTest(key=key), self.assertRaises(ValueError)):
                    seal["run"](args)
                self.assertFalse(args.output.exists())
            after = {**good, "ActiveState": "inactive", "SubState": "dead"}
            calls = iter([good, after])
            with patch.dict(namespace, unit_state=lambda _unit: next(calls), checked_output=lambda _argv: ""):
                seal["run"](args)
            self.assertEqual(read(root / "proof-stopped.json")["status"], "passed-mutation-unit-only")
            log.write_text(log.read_text().replace("bites a", "bites wrong"))
            with self.assertRaises(ValueError):
                seal["mutation_ids"](manifest, log, False)


class NativeRuntimeTests(unittest.TestCase):
    def test_distinct_profiles_and_expected_provider_operators(self) -> None:
        namespace = runpy.run_path(str(SCRIPTS / "audit-native-plugin-runtime.py"))
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            rows = []
            for index, provider in enumerate(["CPUExecutionProvider", "MIGraphX", "MIGraphX"]):
                profile = directory / f"profile-{index}.json"
                events = [{"cat": "Session", "name": "model_run", "ph": "X", "pid": 1, "ts": 0, "dur": 10},
                          {"cat": "Node", "ph": "X", "pid": 1, "ts": 1, "dur": 1,
                           "args": {"op_name": "Relu", "provider": provider}}]
                save(profile, events)
                rows.append(provider + "\t" + str(profile))
            marker = "NATIVE-PLUGIN-RUNTIME PASS: CPU and two real V2 GPU sessions"
            report = directory / "sessions.tsv"
            report.write_text("\n".join([*rows, marker]) + "\n")
            self.assertEqual(len(namespace["audit"](directory)["sessions"]), 3)
            report.write_text("\n".join([rows[0], rows[1], rows[1], marker]) + "\n")
            with self.assertRaises(ValueError):
                namespace["audit"](directory)
            report.write_text("\n".join([*rows, marker]) + "\n")
            profile = directory / "profile-2.json"
            events = read(profile)
            events[-1]["args"]["provider"] = "CPUExecutionProvider"
            profile.write_text(json.dumps(events))
            with self.assertRaises(subprocess.CalledProcessError):
                namespace["audit"](directory)


if __name__ == "__main__":
    unittest.main()
