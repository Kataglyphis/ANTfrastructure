"""Extracted Clang job policies cover parser and fallback semantics, not scheduling capacity or compiler builds."""

import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from functools import lru_cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SUBJECT = Path(sys.argv.pop(1)).resolve()
VALUES = [
    None,
    "",
    "0",
    "00",
    "00012",
    "99999999999999999999999999999999",
    "-1",
    "1.5",
    "1e3",
    " 4",
    "4 ",
    "١٢",
    "0x10",
]


@lru_cache
def snippets(file):
    s = file.read_text()
    a = s.index("# Parse options\n")
    b = s.index("# Validate and compute values", a)
    p = s[a:b]
    a = s.index("# Job count\n")
    b = s.index('info "Installing dependencies...', a)
    j = s[a:b]
    h = ""
    if "_clang_jobs_are_numeric() {" in s:
        h = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1/linux/scripts/tests/test-harness.sh"; t_fn_src "$2" _clang_jobs_are_numeric',
                "_",
                str(ROOT),
                str(file),
            ],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    return h, p, j


def receipt(
    file, mode, value, context, strict, secondary="", mapper=True, status=0, argv=None
):
    h, p, j = snippets(file)
    with tempfile.TemporaryDirectory(prefix="ant-clang-jobs-") as directory:
        work = Path(directory)
        env = dict(
            os.environ,
            WORK=str(work),
            STUB_STATUS=str(status),
            CLANG_BUILD_MB_PER_JOB="1234",
        )
        env.pop("NUM_JOBS", None)
        env.pop("CLANG_NUM_JOBS", None)
        if value is not None:
            env["NUM_JOBS"] = value
        if secondary is not None:
            env["CLANG_NUM_JOBS"] = secondary
        code = r"""set -u
record() { printf '%s\n' "$@" >> "$WORK/trace"; }
info() { printf 'INFO:%s\n' "$*"; }
die() { printf 'DIE:%s\n' "$*" >&2; exit 67; }
usage() { printf USAGE; }
toolchain_unknown_option() { printf 'UNKNOWN:%s\n' "$*" >&2; exit 71; }
nproc() { record nproc "$@"; printf '4\n'; return "$STUB_STATUS"; }
LLVM_TARGETS=unset DO_STRIP=1 USE_CCACHE=0 KEEP_SRC=1 KEEP_BUILD=0 ENABLE_LTO=OFF BOOTSTRAP=OFF
[[ seed123 =~ seed([0-9]+) ]]
trap 'declare -p BASH_REMATCH > "$WORK/state"; printf "NUM:%s:%s\nTARGETS:%s\nSTRIP:%s\n" "${NUM_JOBS+x}" "${NUM_JOBS-}" "$LLVM_TARGETS" "$DO_STRIP" >> "$WORK/state"' EXIT
"""
        if mapper:
            code += 'compute_jobs_with_mem_cap() { record mapper "$@"; printf "17\\n"; return "$STUB_STATUS"; }\n'
        code += h + "\n" + ("set -e\n" if strict else "set +e\n")
        body = p if mode == "cli" else j
        code += (
            "test_case() {\n"
            + body
            + '\nprintf "ARGS:%s" "$#"; printf "<%s>" "$@"; printf "\\n";\n}\n'
        )
        code += (
            'if test_case "$@"; then echo RETURN:0; else echo RETURN:$?; fi\n'
            if context == "conditional"
            else 'test_case "$@"\n'
        )
        args = (
            ["--jobs"] + ([] if value is None else [value]) + ["--no-strip"]
            if mode == "cli"
            else []
        )
        if mode == "cli" and value is None:
            args = ["--jobs"]
        q = subprocess.run(
            ["bash", "-c", code, "_", *(args if argv is None else argv)],
            env=env,
            text=True,
            capture_output=True,
            check=False,
            timeout=5,
        )
        return {
            "rc": q.returncode,
            "out": q.stdout,
            "err": re.sub(r"line [0-9]+:", "line N:", q.stderr),
            "trace": (work / "trace").read_text() if (work / "trace").exists() else "",
            "state": (work / "state").read_text(),
        }


def capture(file):
    result = {}
    for mode in ["cli", "selection"]:
        for value in VALUES:
            for context in ["direct", "conditional"]:
                for strict in [False, True]:
                    key = json.dumps([mode, value, context, strict])
                    result[key] = receipt(file, mode, value, context, strict)
    for value, secondary, mapper, status in [
        (None, None, True, 0),
        ("", None, True, 0),
        ("bad", "03", True, 0),
        ("", "", True, 41),
        ("", "", False, 0),
        ("", "", False, 47),
        ("bad", "bad", False, 0),
    ]:
        for context in ["direct", "conditional"]:
            for strict in [False, True]:
                key = json.dumps(
                    ["fallback", value, secondary, mapper, status, context, strict]
                )
                result[key] = receipt(
                    file, "selection", value, context, strict, secondary, mapper, status
                )
    return result


class ClangJobPolicy(unittest.TestCase):
    def test_original_receipts(self):
        expected = json.loads(
            Path(__file__).with_name("clang-job-receipts.json").read_text()
        )
        self.assertEqual(132, len(expected))
        self.assertEqual(expected, capture(SUBJECT))

    def test_independent_numeric_policy(self):
        for value in ["0", "00", "00012", "99999999999999999999999999999999"]:
            with self.subTest(value=value):
                got = receipt(
                    SUBJECT, "selection", value, "direct", True, secondary="7"
                )
                self.assertEqual(0, got["rc"])
                self.assertEqual("", got["trace"])
                self.assertIn("NUM:x:" + value + "\n", got["state"])
                self.assertIn('[0]="' + value + '"', got["state"])
        empty = receipt(SUBJECT, "selection", "", "direct", True, secondary="")
        self.assertIn('[0]="seed123" [1]="123"', empty["state"])
        invalid = receipt(SUBJECT, "selection", "bad", "direct", True, secondary="bad")
        self.assertIn("declare -a BASH_REMATCH=()", invalid["state"])

    def test_cli_dispatch_and_fallbacks(self):
        for flag in ["--jobs", "-j"]:
            got = receipt(
                SUBJECT, "cli", "07", "direct", True, argv=[flag, "07", "--no-strip"]
            )
            self.assertEqual(0, got["rc"])
            self.assertIn("NUM:x:07\n", got["state"])
            self.assertIn("STRIP:0\n", got["state"])
            self.assertIn("ARGS:0", got["out"])
        missing = receipt(SUBJECT, "cli", None, "direct", True)
        self.assertEqual(67, missing["rc"])
        self.assertEqual("DIE:--jobs requires a numeric argument\n", missing["err"])
        absent = receipt(
            SUBJECT, "selection", None, "conditional", True, secondary=None
        )
        self.assertEqual(1, absent["rc"])
        self.assertIn("CLANG_NUM_JOBS: unbound variable", absent["err"])
        mapper = receipt(
            SUBJECT, "selection", "", "direct", True, secondary="", status=41
        )
        self.assertEqual(41, mapper["rc"])
        self.assertEqual("mapper\n\n1234\n", mapper["trace"])
        fallback = receipt(
            SUBJECT,
            "selection",
            "",
            "direct",
            True,
            secondary="",
            mapper=False,
            status=47,
        )
        self.assertEqual(0, fallback["rc"])
        self.assertIn("NUM:x:4\n1\n", fallback["state"])
        self.assertEqual("nproc\n", fallback["trace"])


if __name__ == "__main__":
    unittest.main()
