"""Real host staging and captured cross-stage dispatch prove transport and raw failures, not BuildKit reuse, images or GPU acceptance."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CORE = ROOT / "linux/scripts/01-core"
DRIVER = r"""
set -euo pipefail
_BUILD_HELPERS_LOADED=1 source "$CONTEXT"
is_dry_run() { [[ "$DRY" == 1 ]]; }
python3() {
  printf '%s\0' "$@" >> "$PY_CALLS"
  if [[ "$FAIL_POINT" == query && "$3" == --profile-for ]]; then return 41; fi
  if [[ "$FAIL_POINT" == stage && "$3" != --profile-for ]]; then return 43; fi
  command python3 "$@"
}
if [[ "$FAIL_POINT" == mkdir ]]; then mkdir() { return 71; }; fi
if [[ "$FAIL_POINT" == mktemp ]]; then mktemp() { return 73; }; fi
if [[ "$FAIL_POINT" == loader ]]; then _CM_DIR="$MISSING"; fi
args=("original argument" "--existing")
if [[ "$WIRED" == 1 ]]; then
  source "$HARNESS"
  t_source_functions "$CROSS_STAGE" cross_stage_run || exit "$?"
  cross_stage_is_per_arch() { return 0; }
  cross_stage_dockerfile() { printf '%s' "$DOCKERFILE"; }
  cross_stage_tag() { printf 'repo/context:test'; }
  cross_stage_parent() { :; }
  _cross_stage_run_resolve_parent() { _CROSS_STAGE_PARENT_PIN=""; }
  cross_stage_build_args() { local -n slot="$1"; slot+=(--configured 1); }
  _cross_stage_run_dispatch() { printf '%s\0' "$@" > "$DISPATCH"; }
  _cross_stage_record_local() { return 0; }
  if cross_stage_run sdk amd64 0; then raw=0; else raw=$?; fi
else
  if append_script_closure_context args "$DOCKERFILE"; then raw=0; else raw=$?; fi
fi
printf '%s\0' "${args[@]}" > "$ARGS"
printf '%s' "$raw" > "$STATUS"
"""


class ScriptContextTests(unittest.TestCase):
    """Private outputs use actual selected SDK sources and preserve caller argument boundaries."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="Named script context ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.dockerfile = self.root / "Dockerfile.sdk"
        self.dockerfile.write_text("FROM base\nLABEL org.kataglyphis.build-script-closure=sdk-core\nCOPY --from=hub-scripts / /opt/scripts/\n")
        self.env = dict(os.environ, LC_ALL="C", CONTEXT=str(CORE / "context-management.sh"),
                        DOCKERFILE=str(self.dockerfile), LOG_DIR=str(self.root / "logs with spaces"),
                        ARGS=str(self.root / "args"), STATUS=str(self.root / "status"), DRY="0",
                        FAIL_POINT="", MISSING=str(self.root / "missing/core"), PY_CALLS=str(self.root / "calls"),
                        WIRED="0", HARNESS=str(ROOT / "linux/scripts/tests/test-harness.sh"),
                        CROSS_STAGE=str(CORE / "cross-stage-build.sh"), DISPATCH=str(self.root / "dispatch"))

    def execute(self) -> tuple[int, list[str]]:
        result = subprocess.run(["bash", "-c", DRIVER], env=self.env, capture_output=True, text=True, check=False, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        raw = int((self.root / "status").read_text())
        args = [value.decode() for value in (self.root / "args").read_bytes().split(b"\0")[:-1]]
        return raw, args

    def test_cross_stage_imports_the_required_context_owner(self) -> None:
        result = subprocess.run(["bash", "-c", 'source "$1"; declare -F append_script_closure_context', "_",
                                 str(CORE / "cross-stage-build.sh")],
                                capture_output=True, text=True, check=False, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "append_script_closure_context")

    def test_cache_scan_keeps_required_parser_failures_fatal(self) -> None:
        source = (ROOT / "linux/scripts/tests/test-sccache-s3-level.sh").read_text()
        start = source.index('bad="$(PYTHONPATH=')
        end = source.index('\nt_case "every Dockerfile RUN', start)
        scan = source[start:end]
        for parser_status, expected in ((0, 0), (29, 1)):
            with self.subTest(parser_status=parser_status):
                command = 'python3() { return ' + str(parser_status) + '; }\n' + scan + '\nprintf "scan survived\\n"\n'
                result = subprocess.run(["bash", "-c", command],
                                        env=dict(os.environ, TESTS_DIR=str(CORE.parent / "tests"), LINUX_DIR=str(ROOT / "linux")),
                                        capture_output=True, text=True, check=False, timeout=10)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual("scan survived" in result.stdout, expected == 0)
                if expected:
                    self.assertIn("Dockerfile cache scan failed", result.stderr)

    def test_live_context_preserves_prefix_argv_and_real_selected_bytes(self) -> None:
        raw, args = self.execute()
        self.assertEqual(raw, 0)
        self.assertEqual(args[:3], ["original argument", "--existing", "--build-context"])
        self.assertEqual(len(args), 4)
        name, value = args[3].split("=", 1)
        self.assertEqual(name, "hub-scripts")
        context = Path(value)
        self.assertTrue(context.is_relative_to(self.root / "logs with spaces"))
        records = json.loads((context / "SCRIPT-CLOSURE.json").read_text())
        self.assertEqual(records["profile"], "sdk-core")
        self.assertEqual(len(records["files"]), 24)
        for target, record in records["files"].items():
            self.assertEqual((context / target).read_bytes(), (ROOT / "linux/scripts" / record["source"]).read_bytes())
        self.assertEqual((self.root / "calls").read_bytes().count(b"--profile-for\0"), 1)

    def test_dry_run_queries_without_creating_staging_directories(self) -> None:
        self.env["DRY"] = "1"
        self.assertEqual(self.execute(), (0, ["original argument", "--existing", "--build-context", "hub-scripts=<staged-sdk-core>"]))
        self.assertFalse((self.root / "logs with spaces").exists())
        self.assertEqual((self.root / "calls").read_bytes().count(b"--output\0"), 0)

    def test_legacy_dockerfile_needs_no_context_or_loader(self) -> None:
        self.dockerfile.write_text("FROM base\nRUN true\n")
        self.env["FAIL_POINT"] = "loader"
        self.assertEqual(self.execute(), (0, ["original argument", "--existing"]))
        self.assertFalse((self.root / "calls").exists())
        self.assertFalse((self.root / "logs with spaces").exists())

    def test_missing_unlabeled_file_keeps_the_existing_policy(self) -> None:
        self.dockerfile.unlink()
        self.assertEqual(self.execute(), (0, ["original argument", "--existing"]))

    def test_raw_failures_do_not_append_arguments(self) -> None:
        for phase, expected in (("query", 41), ("stage", 43), ("mkdir", 71), ("mktemp", 73), ("loader", 2)):
            with self.subTest(phase=phase):
                self.env["FAIL_POINT"] = phase
                self.assertEqual(self.execute(), (expected, ["original argument", "--existing"]))

    def test_ambiguous_or_missing_required_profile_refuses(self) -> None:
        cases = ["FROM base\nCOPY --from=hub-scripts / /opt/scripts/\n",
                 "LABEL org.kataglyphis.build-script-closure=sdk-core\nLABEL org.kataglyphis.build-script-closure=sdk-core\n"]
        for text in cases:
            with self.subTest(text=text):
                self.dockerfile.write_text(text)
                self.assertEqual(self.execute(), (2, ["original argument", "--existing"]))
                self.assertFalse((self.root / "logs with spaces").exists())

    def test_real_cross_stage_dispatch_receives_context(self) -> None:
        self.env["WIRED"] = "1"
        raw, _ = self.execute()
        self.assertEqual(raw, 0)
        arguments = (self.root / "dispatch").read_bytes().split(b"\0")[:-1]
        self.assertEqual(arguments[:6], [b"sdk-amd64", b"repo/context:test", str(self.dockerfile).encode(), b"0", b"--configured", b"1"])
        self.assertEqual(arguments[6], b"--build-context")
        self.assertTrue(arguments[7].startswith(b"hub-scripts="))
        self.assertTrue(Path(arguments[7].decode().split("=", 1)[1]).is_dir())

    def test_context_failure_prevents_cross_stage_dispatch(self) -> None:
        self.env.update(WIRED="1", FAIL_POINT="stage")
        raw, _ = self.execute()
        self.assertEqual(raw, 43)
        self.assertFalse((self.root / "dispatch").exists())


if __name__ == "__main__":
    unittest.main()
