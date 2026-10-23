#!/usr/bin/env python3
"""Help bytes and independent runtime consumption remain observable through shared rendering."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(sys.argv.pop(1)).resolve()
TESTS = Path(__file__).parent
RECEIPTS = json.loads(TESTS.joinpath("runtime-sdk-help-receipts.json").read_text())
FIXTURE = """runtime_usage_description() {
  : "${DOC_ONLY_KNOB:-}"
}
runtime_usage_row() {
  runtime_usage_description
  printf '  ALPHA a\\n  BETA b\\n  GAMMA c\\n  DELTA d\\n  EPSILON e\\n  DOC_ONLY_KNOB f\\n'
}
runtime_shared_usage_env_overrides() {
  runtime_usage_row
}
consume() {
  : "${ALPHA:-}${BETA:-}${GAMMA:-}${DELTA:-}${EPSILON:-}"
}
"""


def run(command, **kwargs):
    return subprocess.run(
        command, check=False, capture_output=True, text=True, timeout=15, **kwargs
    )


class HelpContracts(unittest.TestCase):
    def test_full_help_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            guard = Path(temporary)
            for name in ("nerdctl", "buildctl", "curl", "wget", "uv", "git"):
                tool = guard / name
                tool.write_text("#!/bin/sh\nexit 97\n")
                tool.chmod(0o755)
            env = dict(
                os.environ,
                PATH=str(guard) + os.pathsep + os.environ.get("PATH", ""),
                NERDCTL_BIN=str(guard / "nerdctl"),
            )
            for name, expected in RECEIPTS.items():
                with self.subTest(entry=name):
                    result = run(["bash", str(SCRIPTS / name), "--help"], env=env)
                    self.assertEqual(expected["status"], result.returncode)
                    self.assertEqual(expected["stdout"], result.stdout)
                    self.assertEqual(expected["stderr"], result.stderr)

    def test_cross_target_callbacks_keep_raw_values_and_caller_locals(self):
        worker = (
            'source "$1/test-harness.sh"\n'
            'if grep -q "^orchestrator_set_cross_targets()" "$2/lib-orchestrator.sh"; then '
            't_source_functions "$2/lib-orchestrator.sh" orchestrator_set_cross_targets || exit; fi\n'
            't_source_functions "$2/$3" "$4" || exit\n'
            'exercise() { local CROSS_TARGETS="prior targets" _OARG_SHIFT=9 status; '
            '"$1" "$2" "$3"; status=$?; printf "%s\\n%s\\n%s\\n" "$status" "$CROSS_TARGETS" "$_OARG_SHIFT"; }\n'
            'exercise "$4" "$5" "$6"\n'
        )
        for entry, callback in (
            ("build-cross-chain.sh", "_chain_extra_arg"),
            ("build-cross-compiler.sh", "_compiler_extra_arg"),
        ):
            for flag in ("--cross-targets", "--unknown-option"):
                for value in ("", "amd64,arm64", "arm64 space% $(literal)", "arm64\nriscv64"):
                    with self.subTest(entry=entry, flag=flag, value=value):
                        result = run(["bash", "-u", "-c", worker, "_", str(TESTS), str(SCRIPTS), entry, callback, flag, value])
                        expected = f"0\n{value}\n2\n" if flag == "--cross-targets" else "1\nprior targets\n9\n"
                        self.assertEqual(0, result.returncode)
                        self.assertEqual(expected, result.stdout)
                        self.assertEqual("", result.stderr)

    def test_unknown_help_rows_fail_by_name(self):
        result = run(
            [
                "bash",
                "-c",
                'source "$1/test-harness.sh"\nt_source_functions "$2/01-core/runtime-build-fns.sh" runtime_usage_description runtime_usage_row || exit\nruntime_usage_row UNKNOWN_HELP_ROW 25',
                "_",
                str(TESTS),
                str(SCRIPTS),
            ]
        )
        self.assertEqual(1, result.returncode)
        self.assertIn("UNKNOWN_HELP_ROW", result.stderr)

    @staticmethod
    def env_fixture(root, consumer=None, zombie=False):
        scripts = root / "scripts"
        core = scripts / "01-core"
        core.mkdir(parents=True)
        (core / "runtime-build-fns.sh").write_text(FIXTURE)
        (scripts / "lib-runtime-wheels.sh").write_text(":\n")
        if consumer:
            (scripts / consumer).write_text(': "${DOC_ONLY_KNOB:-}"\n')
        test = TESTS / "test-env-contract.sh"
        if zombie:
            test = root / "test-env-contract.sh"
            test.write_text(
                (TESTS / "test-env-contract.sh")
                .read_text()
                .replace("KNOWN_DEAD=()", "KNOWN_DEAD=(ALPHA)")
            )
            (root / "test-harness.sh").write_bytes(
                (TESTS / "test-harness.sh").read_bytes()
            )
        return run(["bash", str(test), str(scripts)])

    def test_catalog_reference_does_not_count_as_runtime_use(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.env_fixture(Path(directory))
            self.assertEqual(1, result.returncode)
            self.assertIn(
                "documented in usage-overrides but referenced NOWHERE",
                result.stdout + result.stderr,
            )
            self.assertIn("DOC_ONLY_KNOB", result.stdout + result.stderr)

    def test_sdk_only_reference_does_not_count_as_runtime_use(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.env_fixture(Path(directory), "build-sdk-artifacts.sh")
            self.assertEqual(1, result.returncode)
            self.assertIn("DOC_ONLY_KNOB", result.stdout + result.stderr)

    def test_runtime_reference_closes_the_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.env_fixture(Path(directory), "lib-runtime-wheels.sh")
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_consumed_known_dead_knob_is_still_a_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.env_fixture(
                Path(directory), "lib-runtime-wheels.sh", zombie=True
            )
            self.assertEqual(1, result.returncode)
            self.assertIn(
                "now CONSUMED but still on KNOWN_DEAD", result.stdout + result.stderr
            )


if __name__ == "__main__":
    unittest.main()
