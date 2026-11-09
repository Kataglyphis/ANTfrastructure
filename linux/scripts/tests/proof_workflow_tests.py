#!/usr/bin/env python3
"""Exercise frozen sources, ownership and observer parsing; no image build or native library is proved."""

import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType
from unittest.mock import patch

SCRIPTS = Path(sys.argv.pop(1)).resolve()
FIXTURE = Path(sys.argv.pop(1)).resolve()
REVISION = sys.argv.pop(1)
sys.path.insert(0, str(SCRIPTS))


def load(name: str, filename: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


RUNNER = load("fixture_preflight_runner", "run-isolated-preflight.py")
WATCH = load("fixture_build_watch", "watch-build-units.py")
PROBE = load("fixture_preflight_status", "preflight-status.py")


class RunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="ant-proof-workflow-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "with spaces"
        self.root.mkdir()
        self.engine = self.root / "nerdctl"
        shutil.copy2(SCRIPTS / "tests/proof_workflow_engine.py", self.engine)
        self.engine.chmod(0o755)
        self.trace = self.root / "engine.jsonl"
        self.state = self.root / "owned-state"
        self.output = self.root / "logs/run"
        self.environment = patch.dict(os.environ, {"PROOF_ENGINE_TRACE": str(self.trace),
                                                   "PROOF_ENGINE_STATE": str(self.state),
                                                   "PATH": str(self.root) + os.pathsep + os.environ["PATH"]})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.origin = patch.object(RUNNER, "ROOT", FIXTURE)
        self.origin.start()
        self.addCleanup(self.origin.stop)

    def runner_args(self) -> argparse.Namespace:
        return argparse.Namespace(revision=REVISION, output=self.output, name="a-retained-run",
                                  jobs=4, memory="12g", engine=str(self.engine))

    def run_fixture(self, mode: str) -> tuple[int, dict[str, object], list[list[str]]]:
        args = self.runner_args()
        with patch.dict(os.environ, {"PROOF_ENGINE_MODE": mode}):
            status = RUNNER.run(args)
        record = json.loads((self.output / "run.json").read_text())
        commands = [json.loads(line) for line in self.trace.read_text().splitlines()]
        self.assertEqual((self.output / "reports").stat().st_mode & 0o777, 0o755)
        self.assertNotIn(["rm", "--force", "b" * 64], commands)
        return status, record, commands

    def test_snapshot_uses_the_selected_commit_and_readonly_source_mount(self) -> None:
        status, record, commands = self.run_fixture("success")
        self.assertEqual(status, 0)
        self.assertEqual(record["status"], "passed")
        self.assertEqual(record["source_revision"], REVISION)
        self.assertEqual((self.output / "source/marker").read_text(), "old\n")
        self.assertEqual((FIXTURE / "marker").read_text(), "dirty\n")
        self.assertEqual((self.output / "preflight.log").read_bytes(), b"worker\xff\n")
        run = next(args for args in commands if args[0] == "run")
        self.assertIn(f"{self.output / 'source'}:/source:ro", run)
        self.assertIn(f"{self.output / 'reports'}:/evidence", run)
        self.assertNotIn(f"{self.output}:/evidence", run)
        self.assertIn(["rm", "--force", "a" * 64], commands)

    def test_worker_failure_keeps_raw_status_and_removes_only_owned_container(self) -> None:
        status, record, _ = self.run_fixture("worker-failure")
        self.assertEqual(status, 37)
        self.assertEqual(record["command_exit_status"], 37)
        self.assertEqual(record["status"], "failed")

    def test_failed_cleanup_cannot_pass(self) -> None:
        status, record, _ = self.run_fixture("cleanup-failure")
        self.assertEqual(status, 1)
        self.assertEqual(record["cleanup_exit_status"], 9)
        self.assertEqual(record["status"], "failed")

    def test_name_collision_never_removes_a_preexisting_container(self) -> None:
        status, record, commands = self.run_fixture("name-collision")
        self.assertEqual(status, 125)
        self.assertEqual(record["status"], "failed")
        self.assertFalse(any(args[0] == "rm" for args in commands))

    def test_success_without_created_container_evidence_fails(self) -> None:
        status, record, _ = self.run_fixture("no-cid")
        self.assertEqual(status, 1)
        self.assertEqual(record["status"], "failed")

    def test_interrupted_worker_does_not_invent_a_command_exit_status(self) -> None:
        with patch.object(RUNNER, "run_logged", side_effect=SystemExit(143)), self.assertRaises(SystemExit) as interrupted:
            RUNNER.run(self.runner_args())
        self.assertEqual(interrupted.exception.code, 143)
        record = json.loads((self.output / "run.json").read_text())
        self.assertIsNone(record["command_exit_status"])
        self.assertEqual(record["interrupted_exit_status"], 143)
        self.assertEqual(record["status"], "failed")
        self.assertEqual(record["cleanup_exit_status"], 0)
        self.assertEqual((self.output / "reports").stat().st_mode & 0o777, 0o755)

    def test_native_probe_keeps_its_cleanup_trap_and_raw_failure_status(self) -> None:
        tree = self.root / "probe-tree"
        (tree / "01-core").mkdir(parents=True)
        (tree / "tests").mkdir()
        (tree / "03-media/runtime").mkdir(parents=True)
        shutil.copy2(SCRIPTS / "probe-ort-plugin.sh", tree / "probe-ort-plugin.sh")
        (tree / "01-core/python-probe.sh").write_text('ci_image_python_require() { PREFLIGHT_PYTHON="$PROBE_PYTHON"; export PREFLIGHT_PYTHON; }\n')
        (tree / "03-media/runtime/assemble-torch-app.sh").write_text("fixture source\n")
        (tree / "tests/test-harness.sh").write_text("trap 'printf exited > \"$PROBE_HARNESS_EXIT\"' EXIT\n" +
            "t_fn_src() { printf '%s\\n' 'verify_ort_plugin_library() { printf \"%s\\n\" \"$1\" \"$2\" > \"$PROBE_CALL_TRACE\"; return \"$PROBE_NATIVE_STATUS\"; }'; }\n")
        binary = self.root / "probe-bin"
        binary.mkdir()
        uv = binary / "uv"
        uv.write_text('#!/usr/bin/env bash\nmkdir -p "$2"\nprintf "%s" "$2" > "$PROBE_VENV_TRACE"\n')
        uv.chmod(0o755)
        modules = self.root / "modules/lib"
        modules.mkdir(parents=True)
        (modules / "libonnxruntime_ep_tensorrt.so").write_bytes(b"fixture module bytes")
        environment = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                           PROBE_PYTHON=sys.executable, PROBE_HARNESS_EXIT=str(self.root / "harness-exit"),
                           PROBE_CALL_TRACE=str(self.root / "probe-call"), PROBE_VENV_TRACE=str(self.root / "venv"),
                           ORT_TENSORRT_EP_ROOT=str(modules.parent))
        for status in (0, 27):
            environment["PROBE_NATIVE_STATUS"] = str(status)
            evidence = self.root / f"native-{status}"
            result = subprocess.run(["bash", str(tree / "probe-ort-plugin.sh"), "tensorrt", str(evidence)],
                                    env=environment, capture_output=True, check=False)
            self.assertEqual(result.returncode, status, result.stderr)
            record = json.loads((evidence / "evidence.json").read_text())
            self.assertEqual(record["exit_code"], status)
            self.assertEqual(record["status"], "passed-native-load-only" if status == 0 else "failed")
            self.assertTrue((evidence / "verify-function.sh").is_file())
            self.assertFalse(Path((self.root / "venv").read_text()).exists())
            self.assertTrue((self.root / "harness-exit").is_file())
            self.assertEqual((self.root / "probe-call").read_text().splitlines(),
                             ["ORT_TENSORRT_EP_ROOT", "libonnxruntime_ep_tensorrt.so"])

    def test_explicit_image_and_nerdctl_security_option_reach_existing_runner(self) -> None:
        image = "example.invalid/image@sha256:" + "c" * 64
        result = subprocess.run(["bash", str(SCRIPTS / "run-in-ci-image.sh"), str(FIXTURE),
                                 "--engine", str(self.engine), "--image", image, "--", "printf", "literal $value"],
                                capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(self.trace.read_text().splitlines()[-1])
        self.assertIn(image, args)
        self.assertIn("apparmor=unconfined", args)
        self.assertIn("literal\\ \\$value", args[-1])

    def test_existing_runner_value_options_and_empty_refusals(self) -> None:
        command = ["bash", str(SCRIPTS / "run-in-ci-image.sh"), str(FIXTURE),
                   "--engine", str(self.engine), "--image", "example.invalid/image",
                   "--platform", "linux/arm64", "--workdir", "/tmp/with spaces", "--name", "fixture",
                   "--user", "1000:1000", "--keep-container", "--mount-hub-scripts", "--", "true"]
        result = subprocess.run(command, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(self.trace.read_text().splitlines()[-1])
        self.assertNotIn("--rm", args)
        for option, value in (("--platform", "linux/arm64"), ("--name", "fixture"),
                              ("--user", "1000:1000"), ("-w", "/tmp/with spaces")):
            self.assertEqual(args[args.index(option) + 1], value)
        self.assertIn(f"{SCRIPTS.parents[1]}:/opt/kataglyphis-scripts:ro", args)
        trace = self.trace.read_text()
        for option in ("--image", "--engine", "--platform", "--workdir", "--name", "--user"):
            for value in ([], ["", "--", "true"]):
                result = subprocess.run(["bash", str(SCRIPTS / "run-in-ci-image.sh"), str(FIXTURE), option, *value],
                                        capture_output=True, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.trace.read_text(), trace)


class StatusTests(unittest.TestCase):
    def test_running_success_field_is_not_a_terminal_verdict(self) -> None:
        unit = {"Id": "live.service", "LoadState": "loaded", "ActiveState": "active",
                "MainPID": "42", "Result": "success", "ExecMainStatus": "0",
                "ExecMainExitTimestampMonotonic": "0"}
        text = "\n".join(f"{key}={value}" for key, value in unit.items())
        self.assertEqual(WATCH.parse_units(text), [unit])
        self.assertFalse(WATCH.terminal(unit))
        self.assertFalse(WATCH.terminal(dict(unit, ActiveState="inactive", MainPID="0")))
        self.assertTrue(WATCH.terminal(dict(unit, ActiveState="inactive", MainPID="0", ExecMainExitTimestampMonotonic="123")))
        with self.assertRaises(ValueError):
            WATCH.parse_units(text.replace("LoadState=loaded", "LoadState=not-found"))

    def test_preflight_probe_finds_semantic_outputs_after_job_order_changes(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ant-preflight-status-") as temporary:
            root = Path(temporary)
            jobs = root / "ordered-jobs.fixture"
            jobs.mkdir()
            (jobs / "0.out").write_text("no w/crlf shell scripts\n")
            (jobs / "0.rc").write_text("0\n")
            (jobs / "17.out").write_text("=== mutation gate: can these tests fail? ===\n[1/4]   bites   good\n[2/4] FAIL: rejected baseline\n")
            (jobs / "17.rc").write_text("1\n")
            (jobs / "8.out").write_text("All linux script test suites passed (12 suites, 34 assertions).\n")
            (jobs / "8.rc").write_text("0\n")
            status = PROBE.read_status(PROBE.find_jobs(root))
            self.assertEqual(status["completed_jobs"], 3)
            self.assertEqual(status["failed_jobs"], {"17": 1})
            self.assertEqual(status["mutation"]["proved"], 1)
            self.assertEqual(len(status["mutation"]["failures"]), 1)
            self.assertEqual(status["script_tests"]["assertions"], 34)
            (jobs / "9.rc").write_text("\n")
            self.assertEqual(PROBE.read_status(jobs)["completed_jobs"], 3)
            second = root / "ordered-jobs.second"
            second.mkdir()
            (second / "0.out").write_text("no w/crlf shell scripts\n")
            with self.assertRaises(ValueError):
                PROBE.find_jobs(root)
            self.assertIsNone(PROBE.read_status(None)["mutation"])

    def test_native_probe_refuses_unknown_provider_and_unmarked_host(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ant-probe-cli-") as temporary:
            environment = dict(os.environ)
            environment.pop("PYTHON_MAJOR_MINOR", None)
            for provider in ("unknown", "tensorrt"):
                result = subprocess.run(["bash", str(SCRIPTS / "probe-ort-plugin.sh"), provider, temporary + "/output"],
                                        env=environment, capture_output=True, check=False)
                self.assertEqual(result.returncode, 2)
                self.assertFalse(Path(temporary, "output").exists())


if __name__ == "__main__":
    unittest.main()
