#!/usr/bin/env python3
"""Fake compiler receipts cover source fixtures and validation policy, not compiled sanitizer or libFuzzer behavior."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[3]
SUBJECT = Path(sys.argv.pop(1)).resolve()
FUNCTIONS = [
    "validate_fail",
    "_vc_elf_machine_header",
    "_vc_elf_header_matches",
    "_artifact_source_check_target_elf",
    "_artifact_source_check_swapped_gcc",
    "_artifact_source_check_host_gcc",
    "_artifact_source_check_native_gcc",
    "_smoke_gcc_sanitizers",
    "_smoke_clang_libfuzzer",
    "_vc_source_fixture",
    "_vc_gcc_version_matches",
    "_smoke_gcc_sanitizer_source",
    "_smoke_gcc_sanitizer_probe",
    "_smoke_clang_fuzzer_source",
    "_smoke_clang_fuzzer_probe",
]
DRIVER = r"""set -euo pipefail
source "$FUNCTIONS"
record() { builtin printf '%s\n' "$@" >> "$TRACE"; }
mktemp() { record mktemp "$@"; command mkdir -p "$WORK/tmp"; builtin printf '%s\n' "$WORK/tmp"; return "$TEMP_STATUS"; }
printf() {
 case "${1:-}" in '#include <sanitizer/'*|'int LLVMFuzzerTestOneInput'*)
   record write-source
   if [ "$WRITE_STATUS" != 0 ]; then builtin printf partial-source; return "$WRITE_STATUS"; fi ;;
 esac
 builtin printf "$@"
}
rm() { record rm "$@"; [ "$REMOVE_STATUS" = 0 ] || return "$REMOVE_STATUS"; command rm "$@"; }
_compile() {
 local _fixture_tool="$1" _fixture_output='' _fixture_source='' _fixture_prev='' _fixture_arg
 shift
 record "compiler:$_fixture_tool" "$@" "scope-d:${d-<unset>}" "scope-dyn:${dyn-<unset>}"
 for _fixture_arg in "$@"; do
  [ "$_fixture_prev" != -o ] || _fixture_output="$_fixture_arg"
  case "$_fixture_arg" in *.c|*.cpp) _fixture_source="$_fixture_arg" ;; esac
  _fixture_prev="$_fixture_arg"
 done
 if [ -f "$_fixture_source" ]; then record 'source-begin'; command cat "$_fixture_source" >> "$TRACE"; record 'source-end'; fi
 echo compiler-stdout
 echo compiler-stderr >&2
 [ "$COMPILE_STATUS" = 0 ] || return "$COMPILE_STATUS"
 command cp "$PROGRAM" "$_fixture_output"; command chmod +x "$_fixture_output"
}
g++() { _compile g++ "$@"; }
clang() { _compile clang "$@"; }
pipeline_record() { builtin printf '%s\n' "$@" >> "$WORK/pipeline-$1"; }
readelf() { if [ "${1:-}" = -h ]; then pipeline_record readelf "$@"; else record readelf "$@"; fi; builtin printf '%s' "$ELF_TEXT"; echo elf-stderr >&2; return "$ELF_STATUS"; }
head() { pipeline_record head "$@"; command head "$@"; return "$HEAD_STATUS"; }
grep() { if [ "${1:-}" = "Machine:" ]; then pipeline_record grep "$@"; else record grep "$@"; fi; if [ "$GREP_STATUS" != 0 ]; then command cat >/dev/null; return "$GREP_STATUS"; fi; command grep "$@"; }
arch_to_elf_machine() { record architecture "$@"; builtin printf '%s' "$EXPECTED_MACHINE"; return "$ARCH_STATUS"; }
arch_deb_multiarch_triplet_for() { record triple "$@"; echo fixture-target; }
_VALIDATE_ERRORS=0
d=caller-d; dyn=caller-dyn
trap 'builtin printf "errors=%s\nd=%s\ndyn=%s\n" "$_VALIDATE_ERRORS" "${d-<unset>}" "${dyn-<unset>}" > "$WORK/state"' EXIT
if [ "$CONTEXT" = conditional ]; then
 if "$OPERATION"; then exit 0; else exit "$?"; fi
fi
"$OPERATION"
"""
PROGRAM = """#!/usr/bin/env bash
printf 'run:%s\\n' "$*" >> "$TRACE"
echo run-stdout
echo run-stderr >&2
exit "$RUN_STATUS"
"""
COMPILER = """#!/usr/bin/env bash
printf 'version:%s\\n' "$*" >> "$TRACE"
if [ "$1" = -dumpmachine ]; then printf '%s' "$TRIPLE"; else printf '%s' "$VERSION_TEXT"; fi
echo version-stderr >&2
exit "$VERSION_STATUS"
"""
SMOKE_CASES = {
    "success": {},
    "temp-failure": {"TEMP_STATUS": "23"},
    "write-failure": {"WRITE_STATUS": "29"},
    "compile-failure": {"COMPILE_STATUS": "31"},
    "run-failure": {"RUN_STATUS": "37"},
    "cleanup-failure": {"REMOVE_STATUS": "41"},
    "readelf-failure-with-data": {"ELF_STATUS": "43"},
    "head-failure": {"HEAD_STATUS": "47"},
    "grep-failure": {"GREP_STATUS": "53"},
    "missing-ubsan": {"ELF_TEXT": " NEEDED libasan.so.8\n"},
    "missing-asan": {"ELF_TEXT": " NEEDED libubsan.so.1\n"},
    "missing-both": {"ELF_TEXT": ""},
}
VERSION_CASES = {
    "matching": {},
    "version-failure-with-match": {"VERSION_STATUS": "31"},
    "wrong-first-line": {"VERSION_TEXT": "gcc 1.0.0\ngcc16.2.0\n"},
    "empty-version": {"VERSION_TEXT": ""},
    "elf-wrong": {"VERSION_TEXT": "wrong\n", "ELF_TEXT": " Machine: X86-64\n"},
    "elf-failure-with-data": {"VERSION_TEXT": "wrong\n", "ELF_STATUS": "37"},
    "arch-failure-with-data": {"VERSION_TEXT": "wrong\n", "ARCH_STATUS": "41"},
    "arch-empty": {"VERSION_TEXT": "wrong\n", "EXPECTED_MACHINE": ""},
    "missing-binary": {"MISSING_BINARY": "yes"},
    "invalid-version-regex": {"GCC_VERSION": "["},
    "head-failure-with-data": {"HEAD_STATUS": "43"},
    "grep-failure": {"GREP_STATUS": "47"},
}


def functions(file: Path) -> str:
    text = file.read_text()
    names = [n for n in FUNCTIONS if n + "() {" in text]
    command = 'source "$1/linux/scripts/tests/test-harness.sh"; shift; file="$1"; shift; for fn in "$@"; do t_fn_src "$file" "$fn" || exit; done'
    return subprocess.run(
        ["bash", "-c", command, "_", str(ROOT), str(file), *names],
        capture_output=True,
        text=True,
        check=True,
    ).stdout


def one(
    file: Path,
    source: str,
    operation: str,
    case: dict[str, str],
    context: str,
    version: bool,
) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="ant-validator-case-") as directory:
        work = Path(directory)
        script = work / "functions.sh"
        script.write_text(source.replace("/opt", str(work / "opt")))
        program = work / "program"
        program.write_text(PROGRAM)
        program.chmod(0o755)
        env = dict(
            os.environ,
            WORK=str(work),
            LC_ALL="C",
            FUNCTIONS=str(script),
            TRACE=str(work / "trace"),
            PROGRAM=str(program),
            CONTEXT=context,
            OPERATION=operation,
            TEMP_STATUS="0",
            WRITE_STATUS="0",
            COMPILE_STATUS="0",
            RUN_STATUS="0",
            REMOVE_STATUS="0",
            ELF_STATUS="0",
            HEAD_STATUS="0",
            GREP_STATUS="0",
            ARCH_STATUS="0",
            EXPECTED_MACHINE="AArch64",
            TRIPLE="fixture-target",
            VERSION_STATUS="0",
            VERSION_TEXT="gcc fixture 16.2.0\n",
            GCC_VERSION="16.2.0",
            BUILD_MODE="native",
            _VCS_TARGET_ARCH="arm64",
            _VCS_GCC_PREFIX=str(work / "host"),
        )
        env["ELF_TEXT"] = (
            " Machine: AArch64\n"
            if version
            else " NEEDED libasan.so.8\n NEEDED libubsan.so.1\n"
        )
        env.update(case)
        for prefix in (
            work / "host",
            work / "opt" / ("gcc-" + env["GCC_VERSION"] + "-native-arm64"),
        ):
            (prefix / "bin").mkdir(parents=True)
            if case.get("MISSING_BINARY") != "yes":
                path = prefix / "bin/gcc"
                path.write_text(COMPILER)
                path.chmod(0o755)
        result = subprocess.run(
            ["bash", "-c", DRIVER],
            env=env,
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        return result_receipt(result, work)


def result_receipt(
    result: subprocess.CompletedProcess[str], work: Path
) -> dict[str, Any]:
    normalize = lambda value: value.replace(str(work), "WORK")
    files = [
        [str(path.relative_to(work)), path.read_text()]
        for path in sorted((work / "tmp").rglob("*"))
        if path.is_file()
    ]
    return {
        "status": result.returncode,
        "stdout": normalize(result.stdout),
        "stderr": normalize(result.stderr),
        "trace": normalize((work / "trace").read_text())
        if (work / "trace").exists()
        else "",
        "pipeline_calls": {
            tool: normalize((work / ("pipeline-" + tool)).read_text())
            if (work / ("pipeline-" + tool)).exists()
            else ""
            for tool in ("readelf", "head", "grep")
        },
        "state": (work / "state").read_text().replace(str(work), "WORK"),
        "remaining": files,
    }


def capture(file: Path) -> dict[str, dict[str, Any]]:
    source = functions(file)
    results = {}
    for operation, cases, version in [
        ("_smoke_gcc_sanitizers", SMOKE_CASES, False),
        ("_smoke_clang_libfuzzer", SMOKE_CASES, False),
        ("_artifact_source_check_host_gcc", VERSION_CASES, True),
        ("_artifact_source_check_native_gcc", VERSION_CASES, True),
    ]:
        for name, case in cases.items():
            for context in ("strict", "conditional"):
                results[operation + ":" + name + ":" + context] = one(
                    file, source, operation, case, context, version
                )
    return results


class ValidatorProbes(unittest.TestCase):
    def test_original_receipts(self: "ValidatorProbes") -> None:
        expected = json.loads(
            Path(__file__).with_name("validator-probe-receipts.json").read_text()
        )
        actual = capture(SUBJECT)
        for name, receipt in expected.items():
            with self.subTest(case=name):
                self.assertEqual(receipt, actual[name])

    def test_probe_callback_errexit(self: "ValidatorProbes") -> None:
        with tempfile.TemporaryDirectory(prefix="ant-validator-callback-") as temporary:
            source = Path(temporary) / "functions.sh"
            source.write_text(functions(SUBJECT))
            command = r"""set -euo pipefail
source "$1"
write_fixture() { printf fixture > "$d/source"; }
probe_fixture() { printf before; false; printf after; }
_vc_source_fixture write_fixture probe_fixture
"""
            result = subprocess.run(
                ["bash", "-c", command, "_", str(source)],
                env=dict(os.environ, TMPDIR=temporary),
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
            self.assertEqual(1, result.returncode)
            self.assertEqual("before", result.stdout)

    def test_independent_policies(self: "ValidatorProbes") -> None:
        actual = capture(SUBJECT)
        gcc = "_smoke_gcc_sanitizers:"
        fuzz = "_smoke_clang_libfuzzer:"
        self.assertIn(
            "libasan+libubsan NEEDED", actual[gcc + "success:strict"]["stdout"]
        )
        self.assertIn("scope-dyn:\n", actual[gcc + "success:strict"]["trace"])
        self.assertIn("scope-dyn:caller-dyn", actual[fuzz + "success:strict"]["trace"])
        self.assertEqual(
            "errors=0\nd=caller-d\ndyn=caller-dyn\n",
            actual[gcc + "success:strict"]["state"],
        )
        self.assertEqual(23, actual[gcc + "temp-failure:strict"]["status"])
        self.assertEqual(0, actual[gcc + "temp-failure:conditional"]["status"])
        self.assertEqual(29, actual[fuzz + "write-failure:strict"]["status"])
        self.assertEqual(0, actual[fuzz + "write-failure:conditional"]["status"])
        self.assertEqual(41, actual[gcc + "cleanup-failure:strict"]["status"])
        self.assertEqual(41, actual[gcc + "cleanup-failure:conditional"]["status"])
        self.assertIn(
            "COMPILER FAIL [gcc-sanitizers]",
            actual[gcc + "missing-ubsan:strict"]["stderr"],
        )
        self.assertIn(
            "COMPILER FAIL [clang-libfuzzer]",
            actual[fuzz + "run-failure:strict"]["stderr"],
        )
        self.assertNotIn("run-stdout", actual[fuzz + "success:strict"]["stdout"])
        self.assertEqual([], actual[gcc + "success:strict"]["remaining"])
        host = "_artifact_source_check_host_gcc:"
        native = "_artifact_source_check_native_gcc:"
        self.assertIn(
            "reports gcc fixture 16.2.0",
            actual[host + "version-failure-with-match:strict"]["stdout"],
        )
        self.assertIn(
            "cross-built ELF", actual[native + "wrong-first-line:strict"]["stdout"]
        )
        self.assertIn(
            "COMPILER FAIL [host-gcc-missing]",
            actual[host + "missing-binary:strict"]["stderr"],
        )


if __name__ == "__main__":
    unittest.main()
