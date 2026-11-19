#!/usr/bin/env python3
"""Exercise frozen sources, ownership and observer parsing; no image build or native library is proved."""

import argparse
import importlib.util
import json
import os
import shlex
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
OWNER = load("fixture_owned_containers", "owned_containers.py")


class EngineFixture(unittest.TestCase):
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


class RunnerTests(EngineFixture):
    def runner_args(self) -> argparse.Namespace:
        return argparse.Namespace(revision=REVISION, output=self.output, name="a-retained-run",
                                  jobs=4, memory="12g", engine=str(self.engine), image=None, native_tools_cache=None,
                                  fast_ubuntu_mirror_url=None, run_id="1" * 32)

    def run_fixture(self, mode: str, args: argparse.Namespace | None = None) -> tuple[int, dict[str, object], list[list[str]]]:
        args = args or self.runner_args()
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
        self.assertIn("--init", run)
        self.assertIn(f"{self.output / 'source'}:/source:ro", run)
        self.assertIn(f"{self.output / 'reports'}:/evidence", run)
        self.assertNotIn(f"{self.output}:/evidence", run)
        self.assertIn(["rm", "--force", "a" * 64], commands)
        self.assertIn('ISOLATED_PREFLIGHT_UBUNTU_MIRROR_URL=', run)
        self.assertIsNone(record['fast_ubuntu_mirror_url'])

    def test_explicit_mirror_reaches_one_container_environment_and_receipt(self) -> None:
        args = self.runner_args()
        args.fast_ubuntu_mirror_url = 'http://de.archive.ubuntu.com/ubuntu/'
        status, record, commands = self.run_fixture('success', args)
        self.assertEqual(status, 0)
        self.assertEqual(record['fast_ubuntu_mirror_url'], args.fast_ubuntu_mirror_url)
        run = next(argv for argv in commands if argv[0] == 'run')
        values = [value for value in run if value.startswith('ISOLATED_PREFLIGHT_UBUNTU_MIRROR_URL=')]
        self.assertEqual(values, ['ISOLATED_PREFLIGHT_UBUNTU_MIRROR_URL=' + args.fast_ubuntu_mirror_url])

    def test_mirror_argument_refusals_precede_output_allocation(self) -> None:
        base = ['runner', '--output', str(self.output), '--name', 'fixture', '--fast-ubuntu-mirror-url']
        for value in ['file:///tmp/mirror', 'http://', 'http://user:password@mirror.invalid/ubuntu/',
                      'http://mirror.invalid/ubuntu/?key=value', 'http://mirror.invalid/ubuntu/#part',
                      'http://mirror.invalid/with space', 'http://[broken', 'http://mirror.invalid:bad/ubuntu/']:
            with self.subTest(value=value), patch.object(sys, 'argv', [*base, value]), self.assertRaises(SystemExit) as error:
                RUNNER.arguments()
            self.assertEqual(error.exception.code, 2)
            self.assertFalse(self.output.exists())
        for value in ['http://de.archive.ubuntu.com/ubuntu/', 'https://mirror.invalid/ubuntu/']:
            with self.subTest(value=value), patch.object(sys, 'argv', [*base, value]):
                self.assertEqual(RUNNER.arguments().fast_ubuntu_mirror_url, value)

    def test_bootstrap_mirror_precedes_apt_preserves_sources_and_raw_failure(self) -> None:
        text = (SCRIPTS / 'isolated-preflight/bootstrap.sh').read_text()
        prefix = text.split('apt-get install', 1)[0]
        anchor = 'configure_preflight_mirror /source/linux/scripts'
        self.assertEqual(prefix.count(anchor), 1)
        for mode in ['disabled', 'enabled', 'failed']:
            with self.subTest(mode=mode):
                root = self.root / mode
                core = root / 'scripts/01-core'
                core.mkdir(parents=True)
                for name in ['use-fast-ubuntu-mirror.sh', 'ubuntu-mirror.sh', 'platform.sh']:
                    shutil.copy2(SCRIPTS / '01-core' / name, core / name)
                if mode == 'failed':
                    (core / 'use-fast-ubuntu-mirror.sh').write_text('#!/bin/bash\nexit 47\n')
                sources = root / 'etc/apt/sources.list.d/ubuntu.sources'
                sources.parent.mkdir(parents=True)
                original = ('Types: deb\nURIs: http://archive.ubuntu.com/ubuntu/ http://security.ubuntu.com/ubuntu/\n'
                            'Suites: resolute resolute-updates resolute-security\nComponents: main\n'
                            'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n')
                sources.write_text(original)
                apt = root / 'apt-get'
                apt.write_text('#!/bin/bash\ncat "$UBUNTU_SOURCES_ROOT/etc/apt/sources.list.d/ubuntu.sources" > "$APT_TRACE"\n')
                apt.chmod(0o755)
                trace = root / 'apt-trace'
                script = root / 'bootstrap-prefix.sh'
                script.write_text(prefix.replace(anchor, 'configure_preflight_mirror ' + shlex.quote(str(root / 'scripts'))))
                environment = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                                   UBUNTU_SOURCES_ROOT=str(root), APT_TRACE=str(trace),
                                   ISOLATED_PREFLIGHT_UBUNTU_MIRROR_URL='' if mode == 'disabled' else 'http://de.archive.ubuntu.com/ubuntu/')
                result = subprocess.run(['bash', str(script)], env=environment, capture_output=True, text=True, timeout=30, check=False)
                self.assertEqual(result.returncode, 47 if mode == 'failed' else 0, result.stderr)
                if mode == 'failed':
                    self.assertFalse(trace.exists())
                else:
                    expected = original if mode == 'disabled' else original.replace('http://archive.ubuntu.com/ubuntu/', 'http://de.archive.ubuntu.com/ubuntu/').replace('http://security.ubuntu.com/ubuntu/', 'http://de.archive.ubuntu.com/ubuntu/')
                    self.assertEqual(trace.read_text(), expected)
                    self.assertEqual(sources.read_text(), expected)

    def test_explicit_image_and_readonly_native_cache_reach_the_canonical_runner(self) -> None:
        args = self.runner_args()
        args.image = "example.invalid/cached-tool@sha256:" + "d" * 64
        args.native_tools_cache = self.root / "retained SDK"
        args.native_tools_cache.mkdir()
        with patch.object(RUNNER, "base_image", side_effect=AssertionError("explicit image was ignored")):
            status, record, commands = self.run_fixture("success", args)
        self.assertEqual(status, 0)
        self.assertEqual(record["owner_run_id"], args.run_id)
        self.assertEqual(record["image"], args.image)
        self.assertEqual(record["image_selection"], "explicit")
        self.assertEqual(record["native_tools_cache"], str(args.native_tools_cache))
        run = next(argv for argv in commands if argv[0] == "run")
        self.assertIn(args.image, run)
        self.assertIn(f"{args.native_tools_cache}:/opt/preflight-native-tools:ro", run)
        self.assertIn("--init", run)

    def test_missing_native_cache_refuses_before_allocating_a_run(self) -> None:
        argv = ["runner", "--output", str(self.output), "--name", "fixture", "--native-tools-cache", str(self.root / "absent")]
        with patch.object(sys, "argv", argv), self.assertRaises(SystemExit) as error:
            RUNNER.arguments()
        self.assertEqual(error.exception.code, 2)
        self.assertFalse(self.output.exists())

    def test_malformed_ownership_token_refuses_before_allocating_a_run(self) -> None:
        argv = ["runner", "--output", str(self.output), "--name", "fixture", "--run-id", "not-a-token"]
        with patch.object(sys, "argv", argv), self.assertRaises(SystemExit) as error:
            RUNNER.arguments()
        self.assertEqual(error.exception.code, 2)
        self.assertFalse(self.output.exists())

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


class CleanupTests(EngineFixture):
    def setUp(self) -> None:
        super().setUp()
        self.token = "c" * 32
        self.label = "org.kataglyphis.fixture-proof"
        self.state.write_text(f"{self.label}={self.token}")
        self.cidfile = self.root / "container.cid"
        self.cidfile.write_text("a" * 64 + "\n")
        self.owner = OWNER.OwnedContainers(str(self.engine), self.label, self.token)

    def test_remove_verifies_absence_and_preserves_foreign_container(self) -> None:
        self.assertEqual(self.owner.cleanup(cidfile=self.cidfile), 0)
        self.assertFalse(self.state.exists())
        calls = [json.loads(line) for line in self.trace.read_text().splitlines()]
        self.assertIn(["inspect", "a" * 64], calls)
        self.assertNotIn(["rm", "--force", "b" * 64], calls)
        self.assertIn(["ps", "-a", "--no-trunc", "--format", "{{.ID}}"], calls)

    def test_successful_remove_that_leaves_container_present_fails(self) -> None:
        with patch.dict(os.environ, {"PROOF_ENGINE_MODE": "remove-lies"}), patch.object(OWNER.time, "sleep"):
            self.assertNotEqual(self.owner.cleanup(cidfile=self.cidfile), 0)

    def test_late_owned_container_cannot_escape_the_final_inventory_check(self) -> None:
        success = subprocess.CompletedProcess([], 0)
        with patch.object(OWNER.OwnedContainers, "ids", side_effect=[{"a" * 64}, {"d" * 64}]), \
                patch.object(OWNER.OwnedContainers, "state", return_value={}), \
                patch.object(OWNER.OwnedContainers, "settled", return_value=True), \
                patch.object(OWNER.subprocess, "run", return_value=success):
            self.assertNotEqual(self.owner.cleanup(), 0)

    def test_retain_stops_running_container_without_removing_its_filesystem(self) -> None:
        self.state.with_suffix(".running").touch()
        self.assertEqual(self.owner.cleanup(retain=True, cidfile=self.cidfile), 0)
        self.assertTrue(self.state.exists())
        self.assertFalse(self.state.with_suffix(".running").exists())
        self.assertNotIn('"rm"', self.trace.read_text())

    def test_retain_checks_real_stopped_state_after_success_and_failure(self) -> None:
        for mode, expected in (("stop-lies", 1), ("stop-failure", 17)):
            with self.subTest(mode=mode), patch.dict(os.environ, {"PROOF_ENGINE_MODE": mode}), patch.object(OWNER.time, "sleep"):
                self.state.with_suffix(".running").touch()
                self.assertEqual(self.owner.cleanup(retain=True, cidfile=self.cidfile), expected)

    def test_already_stopped_retained_container_needs_no_stop(self) -> None:
        self.assertEqual(self.owner.cleanup(retain=True, cidfile=self.cidfile), 0)
        self.assertNotIn('"stop"', self.trace.read_text())

    def test_changed_ownership_and_malformed_inspection_refuse_mutation(self) -> None:
        for mode in ("wrong-label", "wrong-id", "malformed", "missing-state", "inspect-failure", "list-failure"):
            with self.subTest(mode=mode), patch.dict(os.environ, {"PROOF_ENGINE_MODE": mode}):
                with self.assertRaises((TypeError, ValueError, RuntimeError)):
                    self.owner.cleanup(cidfile=self.cidfile)
                self.assertNotIn('"rm"', self.trace.read_text())
                self.assertNotIn('"stop"', self.trace.read_text())

    def test_foreign_or_invalid_cid_file_refuses_mutation(self) -> None:
        for cid in ("b" * 64, "short", "../foreign"):
            with self.subTest(cid=cid), self.assertRaises(ValueError):
                self.cidfile.write_text(cid)
                self.owner.cleanup(cidfile=self.cidfile)
        self.assertNotIn('"rm"', self.trace.read_text())

    def test_absence_before_container_creation_is_successful_cleanup(self) -> None:
        self.state.unlink()
        self.cidfile.unlink()
        self.assertEqual(self.owner.cleanup(cidfile=self.cidfile), 0)

    def test_invalid_label_or_run_token_is_rejected_before_engine_calls(self) -> None:
        for label, token in (("", self.token), ("status=running", self.token), (self.label, ""), (self.label, "old-run")):
            with self.subTest(label=label, token=token), self.assertRaises(ValueError):
                OWNER.OwnedContainers(str(self.engine), label, token)
        self.assertFalse(self.trace.exists())

    def test_retained_state_requires_all_stopped_facts(self) -> None:
        valid = {"Running": False, "Pid": 0, "Status": "exited"}
        self.assertTrue(OWNER.stopped(valid))
        for broken in ({"Running": True}, {"Pid": 42}, {"Pid": False}, {"Status": "running"}):
            with self.subTest(broken=broken):
                self.assertFalse(OWNER.stopped(valid | broken))
        self.assertFalse(OWNER.stopped({}))

    def test_cli_preserves_cleanup_status_failure_receipt_and_existing_evidence(self) -> None:
        output = self.root / "cleanup.json"
        command = [sys.executable, str(SCRIPTS / "cleanup-owned-containers.py"), "--engine", str(self.engine),
                   "--owner-label", self.label, "--run-id", self.token, "--cidfile", str(self.cidfile), "--output", str(output)]
        with patch.dict(os.environ, {"PROOF_ENGINE_MODE": "cleanup-failure"}):
            result = subprocess.run(command, capture_output=True, check=False)
        self.assertEqual(result.returncode, 9, result.stderr)
        record = json.loads(output.read_text())
        self.assertEqual((record["status"], record["exit_status"]), ("failed", 9))
        before, trace = output.read_bytes(), self.trace.read_bytes()
        result = subprocess.run(command, capture_output=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((output.read_bytes(), self.trace.read_bytes()), (before, trace))


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
        self.assertFalse(WATCH.terminal(dict(unit, SubState="exited", MainPID="0")))
        self.assertTrue(WATCH.terminal(dict(unit, SubState="exited", MainPID="0", ExecMainExitTimestampMonotonic="123")))
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
