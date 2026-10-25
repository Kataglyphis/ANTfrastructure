"""Hermetic CLI fixtures cover help exit and binding policy, not process stopping or container verification."""

import json
import os
import shlex
import shutil
import subprocess
import tempfile
import unittest
from collections.abc import Sequence
from functools import lru_cache
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[3]


@lru_cache
def extract(file: Path, fn: str) -> str:
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


DRIVER = r"""
_emit_usage() { printf 'USAGE:%s GRACE:<%s> N:<%s> C:<%s> V:<%s>\n' "$1" "$GRACE_SECS" "$NATIVE_IMAGE" "$CROSS_IMAGE" "$VERBOSE" >&"$STREAM"; return "$USAGE_RC"; }
usage() { _emit_usage plain; }
early_usage() { _emit_usage early; }
late_usage() { _emit_usage late; }
err() { printf 'ERR:%s\n' "$*" >&2; exit 1; }
reject_unknown_option() { printf 'UNKNOWN:%s\n' "$*" >&2; exit 1; }
cross_chain_pidfile_path() { printf pid; }
_stop_resolve_target() { printf 'UNEXPECTED cleanup\n'; }
log() { printf 'LOG:%s\n' "$*"; }
"""


def run(
    case: Sequence[Any], missing: bool = False
) -> list[Any]:
    subject, flag, status, strict, conditional, phase, stream = case
    file = ROOT / (
        "linux/scripts/stop-cross-chain.sh"
        if subject == "stop"
        else "linux/scripts/06-packaging/verify-parity.sh"
    )
    fn = "main" if subject == "stop" else "verify_parity_parse_args"
    callback = "_stop_usage" if subject == "stop" else "_parity_usage"
    code = ("set -euo pipefail\n" if strict else "set -uo pipefail\n") + DRIVER
    code += (
        "GRACE_SECS=15 NATIVE_IMAGE=oldN CROSS_IMAGE=oldC VERBOSE=0\nUSAGE_RC="
        + str(status)
        + " STREAM="
        + str(stream)
        + "\nshopt -s expand_aliases\n"
    )
    if phase != "plain":
        code += "alias usage=early_usage\n"
    if not missing:
        code += extract(
            ROOT / "linux/scripts/01-core/logging.sh", "show_usage_and_exit"
        )
    code += extract(file, callback)
    code += extract(file, fn)
    if phase == "after":
        code += "alias usage=late_usage\n"
    args = (
        ["--timeout", "7 [*]", flag]
        if subject == "stop"
        else ["--native", "native [*]", "--cross", "cross [*]", "--verbose", flag]
    )
    invocation = fn + " " + shlex.join(args)
    code += (
        "if " + invocation + "; then r=0; else r=$?; fi\n"
        if conditional
        else invocation + "\nr=$?\n"
    )
    code += 'printf "FELLTHROUGH:%s\\n" "$r"\n'
    env = dict(os.environ)
    env.pop("BASH_ENV", None)
    result = subprocess.run(
        ["bash", "-c", code],
        env=env,
        capture_output=True,
        text=True,
        timeout=3,
        check=False,
    )
    return [result.returncode, result.stdout, result.stderr]


class HelpExitTests(unittest.TestCase):
    def test_command_prefix_alias_keeps_parser_arguments(
        self: "HelpExitTests",
    ) -> None:
        for subject, relative, name, callback, args in [
            ("stop", "stop-cross-chain.sh", "main", "_stop_usage", ["--timeout", "7"]),
            (
                "parity",
                "06-packaging/verify-parity.sh",
                "verify_parity_parse_args",
                "_parity_usage",
                ["--native", "n", "--cross", "c"],
            ),
        ]:
            with self.subTest(subject=subject):
                code = r"""
set -euo pipefail
usage_alias() { printf 'ARGS:'; printf '<%s>' "$@"; printf '\n'; }
shopt -s expand_aliases
alias usage='usage_alias "$@"'
GRACE_SECS=15 NATIVE_IMAGE=old CROSS_IMAGE=old VERBOSE=0
"""
                code += extract(
                    ROOT / "linux/scripts/01-core/logging.sh", "show_usage_and_exit"
                )
                code += extract(ROOT / "linux/scripts" / relative, callback)
                code += extract(ROOT / "linux/scripts" / relative, name)
                code += (
                    name + " " + shlex.join(args + ["--help", "tail value", ""]) + "\n"
                )
                result = subprocess.run(
                    ["bash", "-c", code], capture_output=True, text=True, check=False
                )
                self.assertEqual(
                    (0, "ARGS:<--help><tail value><>\n", ""),
                    (result.returncode, result.stdout, result.stderr),
                )

    def test_original_receipts(self: "HelpExitTests") -> None:
        rows = json.loads(
            Path(__file__).with_name("cli-help-exit-receipts.json").read_text()
        )
        self.assertEqual(288, len(rows))
        for row in rows:
            with self.subTest(case=row["case"]):
                self.assertEqual(row["receipt"], run(row["case"]))

    def test_missing_helper_stops_conditional_parser(self: "HelpExitTests") -> None:
        for subject in ["stop", "parity"]:
            with self.subTest(subject=subject):
                result = run(
                    [subject, "--help", 0, True, True, "plain", 1], missing=True
                )
                self.assertEqual(127, result[0])
                self.assertEqual("", result[1])
                self.assertIn("show_usage_and_exit", result[2])

    def test_helper_exits_and_preserves_arguments(self: "HelpExitTests") -> None:
        code = (
            extract(ROOT / "linux/scripts/01-core/logging.sh", "show_usage_and_exit")
            + r"""
report() { printf '<%s>' "$@"; printf '\n'; }
show_usage_and_exit report 'spaced [*]' ''
printf FELLTHROUGH
"""
        )
        result = subprocess.run(
            ["bash", "-c", code], capture_output=True, text=True, check=False
        )
        self.assertEqual(
            (0, "<spaced [*]><>\n", ""),
            (result.returncode, result.stdout, result.stderr),
        )

    def test_helper_requires_command(self: "HelpExitTests") -> None:
        code = (
            extract(ROOT / "linux/scripts/01-core/logging.sh", "show_usage_and_exit")
            + "\nshow_usage_and_exit\n"
        )
        result = subprocess.run(
            ["bash", "-c", code], capture_output=True, text=True, check=False
        )
        self.assertEqual(127, result.returncode)
        self.assertEqual("", result.stdout)
        self.assertIn("usage command required", result.stderr)

    def test_copied_closure_and_real_help(self: "HelpExitTests") -> None:
        for row in json.loads(
            Path(__file__).with_name("cli-help-real-receipts.json").read_text()
        ):
            with (
                self.subTest(subject=row["subject"]),
                tempfile.TemporaryDirectory(prefix="ant-copied-cli-help-") as directory,
            ):
                work = Path(directory)
                relative = (
                    "stop-cross-chain.sh"
                    if row["subject"] == "stop"
                    else "06-packaging/verify-parity.sh"
                )
                for leaf in [
                    relative,
                    "01-core/logging.sh",
                    "01-core/chain-lifecycle.sh",
                ]:
                    target = work / leaf
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(ROOT / "linux/scripts" / leaf, target)
                env = dict(os.environ)
                env.pop("BASH_ENV", None)
                env.pop("_LOGGING_SH_LOADED", None)
                result = subprocess.run(
                    ["bash", str(work / relative), "--help"],
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=3,
                    check=False,
                )
                self.assertEqual(
                    row["receipt"], [result.returncode, result.stdout, result.stderr]
                )
                (work / "01-core/logging.sh").write_text(
                    "_LOGGING_SH_LOADED=1\nreturn 0\n"
                )
                code = 'if source "$1" --help; then printf FELLTHROUGH; else printf FELLTHROUGH; fi'
                result = subprocess.run(
                    ["bash", "-c", code, "_", str(work / relative)],
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=3,
                    check=False,
                )
                self.assertEqual(127, result.returncode)
                self.assertEqual("", result.stdout)
                self.assertIn("show_usage_and_exit", result.stderr)


if __name__ == "__main__":
    unittest.main()
