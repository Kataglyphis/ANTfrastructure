"""Offline npm fixtures test interpreter transport, not registry trust or actual tar extraction."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from functools import lru_cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = Path(sys.argv.pop(1)).resolve()
INTEGRITY = "sha512-k1L2OVn+BO+ybXTp8hoQ0vmRjprFk33cvhWWA7DUTmH6EVQnL/8lj0aGRB1De+fFS2Eedj1yflX1BRLSAm7oiw=="


@lru_cache
def extract(file, fn):
    return subprocess.run(
        [
            "bash",
            "-c",
            'source "$1/linux/scripts/tests/test-harness.sh"; t_fn_src "$2" "$3"',
            "_",
            str(ROOT),
            str(file),
            fn,
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout


TOOLS = r"""
record() { printf '%s\0' "$@" >> "$WORK/$1.calls"; }
mktemp() { record mktemp "$@"; mkdir -p "$WORK/tmp"; printf '%s' "$WORK/tmp"; }
mkdir() { record mkdir "$@"; command mkdir "$@"; }
rm() { record rm "$@"; command rm "$@"; }
sleep() { record sleep "$@"; }
warn() { printf 'WARN:%s\n' "$*" >&2; }
info() { printf 'INFO:%s\n' "$*"; [[ "$SCENARIO" != info_failure ]] || return 17; }
curl() {
 record curl "$@"
 if [[ "$3" = 120 ]]; then
  DLCALL=$((DLCALL+1))
  if [[ "$SCENARIO" = download_failure || ( "$SCENARIO" = retry && "$DLCALL" = 1 ) ]]; then
   printf 'download diagnostic\n' >&2; return 23
  fi
  printf '%s' 'npm fixture payload' > "$6"
 else
  printf '%s' "$META"
  printf 'metadata diagnostic\n' >&2
  [[ "$SCENARIO" != metadata_partial ]] || return 23
 fi
}
tar() {
 record tar "$@"; TARCALL=$((TARCALL+1)); printf 'tar stdout\n'
 if [[ "$SCENARIO" = tar_failure || ( "$SCENARIO" = tar_retry && "$TARCALL" = 1 ) ]]; then
  printf 'tar diagnostic\n' >&2; return 37
 fi
 printf '%s' unpacked > "$4/result"
}
_python_impl() {
 record python "$@"
 if [[ "$2" = *'import json,sys'* && "$SCENARIO" = metadata_python_partial ]]; then printf '%s' "$GOOD"; return 29; fi
 if [[ "$2" = *'import hashlib,base64,sys'* && "$SCENARIO" = digest_failure ]]; then printf partial; printf 'digest diagnostic\n' >&2; return 31; fi
 "$REAL_PY" "$@"
}
python3() { printf 'plain\0' >> "$WORK/binding.calls"; _python_impl "$@"; }
early_python() { printf 'early\0' >> "$WORK/binding.calls"; _python_impl "$@"; }
prefix_python() {
 [ "$#" -ge 5 ] && [ "$1" = '@scope/pkg [*]' ] && [ "$2" = '1 [*]' ] && [ "$3" = "$WORK/dest [*]" ] || return 79
 shift 3
 _python_impl "$@"
}
late_python() { printf 'late\0' >> "$WORK/binding.calls"; _python_impl "$@"; }
"""


def run(file, case):
    scenario, strict, conditional, phase = case
    with tempfile.TemporaryDirectory(prefix="ant-npm-python-") as directory:
        work = Path(directory)
        for tool in [
            "curl",
            "python",
            "tar",
            "rm",
            "mkdir",
            "mktemp",
            "sleep",
            "binding",
        ]:
            (work / (tool + ".calls")).write_bytes(b"")
        meta = {"dist": {"integrity": INTEGRITY}}
        if scenario == "metadata_missing":
            meta = {}
        elif scenario == "mismatch":
            meta = {"dist": {"integrity": "sha512-wrong"}}
        metadata = (
            "invalid JSON" if scenario == "metadata_invalid" else json.dumps(meta)
        )
        code = ("set -euo pipefail\n" if strict else "set -uo pipefail\n") + TOOLS
        code += "shopt -s expand_aliases\n"
        if phase == "prefix":
            code += "alias python3='prefix_python \"$@\"'\n"
        elif phase != "plain":
            code += "alias python3=early_python\n"
        code += extract(file, "_npm_python_quiet")
        code += extract(file, "_fetch_npm_package")
        if phase == "after":
            code += "alias python3=late_python\n"
        code += 'REGISTRY="https://registry.invalid/root [*]" DLCALL=0 TARCALL=0\n'
        invocation = '_fetch_npm_package "@scope/pkg [*]" "1 [*]" "$WORK/dest [*]"'
        code += (
            "if " + invocation + "; then rc=0; else rc=$?; fi\n"
            if conditional
            else invocation + "\nrc=$?\n"
        )
        code += (
            'printf "STATUS:%s DOWNLOADS:%s TARS:%s\\n" "$rc" "$DLCALL" "$TARCALL"\n'
        )
        code += "if declare -F _npm_metadata_python >/dev/null || declare -F _npm_digest_python >/dev/null; then printf 'CALLBACKS:LEAK\\n'; else printf 'CALLBACKS:CLEAN\\n'; fi\n"
        env = dict(
            os.environ,
            WORK=str(work),
            SCENARIO=scenario,
            META=metadata,
            GOOD=INTEGRITY,
            REAL_PY=sys.executable,
        )
        result = subprocess.run(
            ["bash", "-c", code],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        norm = lambda s: s.replace(str(work), "@WORK@")
        calls = {p.name: norm(p.read_text()) for p in sorted(work.glob("*.calls"))}
        files = {
            str(p.relative_to(work)): p.read_text()
            for d in ["dest [*]", "tmp"]
            for p in sorted((work / d).rglob("*"))
            if p.is_file()
        }
        return [
            result.returncode,
            norm(result.stdout),
            norm(result.stderr),
            calls,
            files,
        ]


class NpmPythonTransportTests(unittest.TestCase):
    def test_original_receipts(self):
        rows = json.loads(
            Path(__file__).with_name("npm-python-transport-receipts.json").read_text()
        )
        self.assertEqual(144, len(rows))
        for row in rows:
            with self.subTest(case=row["case"]):
                self.assertEqual(row["receipt"], run(SCRIPT, row["case"]))

    def test_prefix_alias_preserves_enclosing_arguments(self):
        result = run(SCRIPT, ["success", True, False, "prefix"])
        self.assertEqual(0, result[0])
        self.assertEqual("", result[2])
        self.assertIn("integrity verified", result[1])
        self.assertEqual({"dest [*]/result": "unpacked"}, result[4])
        self.assertEqual(2, result[3]["python.calls"].count("python\0-c\0"))

    def test_raw_status_quiet_stderr_and_arguments(self):
        code = (
            extract(SCRIPT, "_npm_python_quiet")
            + r"""
provided_python() { printf '<%s>' "$@"; printf '\n'; printf diagnostic >&2; return 27; }
_npm_python_quiet provided_python -c 'quoted [*]' ''
"""
        )
        result = subprocess.run(
            ["bash", "-c", code], capture_output=True, text=True, check=False
        )
        self.assertEqual(
            (27, "<-c><quoted [*]><>\n", ""),
            (result.returncode, result.stdout, result.stderr),
        )


if __name__ == "__main__":
    unittest.main()
