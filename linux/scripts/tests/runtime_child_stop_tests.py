"""Mocked receipts cover advisory signal/reap order and timer status, not real build or image cleanup."""

import itertools
import json
import shlex
import subprocess
import unittest
from functools import lru_cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


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


def receipt(subject, k, w, status, dry, conditional, pid):
    runtime = ROOT / "linux/scripts/01-core/runtime-build-fns.sh"
    chain = ROOT / "linux/scripts/build-cross-chain.sh"
    code = (
        extract(
            ROOT / "linux/scripts/01-core/parallel-loop.sh",
            "parallel_require_child_stop",
        )
        + "\nset -euo pipefail\n"
        + extract(
            ROOT / "linux/scripts/01-core/parallel-loop.sh",
            "parallel_stop_child_advisory",
        )
    )
    code += (
        extract(runtime, "_runtime_timed")
        if subject == "timed"
        else extract(chain, "_chain_disk_watch_stop")
    )
    code += """
date() { printf 100; }
log() { printf 'log:%s\\n' "$*"; }
_runtime_heartbeat() { :; }
is_dry_run() { test "$DRY" = 1; }
kill() { if [[ "$SUBJECT" = timed && "$1" = "$!" ]]; then printf 'kill:<OWN_CHILD>\\n'; else printf 'kill:<%s>\\n' "$1"; fi; printf 'hidden kill\\n' >&2; return "$K"; }
wait() { if [[ "$SUBJECT" = timed && "$1" = "$!" ]]; then printf 'wait:<OWN_CHILD>\\n'; else printf 'wait:<%s>\\n' "$1"; fi; printf 'hidden wait\\n' >&2; if [[ "$SUBJECT" = timed ]]; then builtin wait "$1" || :; fi; return "$W"; }
command_probe() { printf 'command\\n'; return "$STATUS"; }
"""
    code += (
        "DRY="
        + str(dry)
        + " K="
        + str(k)
        + " W="
        + str(w)
        + " STATUS="
        + str(status)
        + " SUBJECT="
        + subject
        + "\n"
    )
    code += "_CHAIN_DISK_WATCH_PID=" + shlex.quote(pid) + "\n"
    invocation = (
        "_runtime_timed probe arm64 command_probe"
        if subject == "timed"
        else "_chain_disk_watch_stop"
    )
    code += (
        "if " + invocation + "; then r=0; else r=$?; fi\n"
        if conditional
        else invocation + "\nr=$?\n"
    )
    code += 'printf \'result:%s pid:<%s>\\n\' "$r" "$_CHAIN_DISK_WATCH_PID"\n'
    result = subprocess.run(
        ["bash", "-c", code], capture_output=True, text=True, timeout=10, check=False
    )
    return [result.returncode, result.stdout, result.stderr]


class ChildStopTests(unittest.TestCase):
    def test_missing_api_refuses_before_spawning(self):
        core = ROOT / "linux/scripts/01-core/parallel-loop.sh"
        runtime = ROOT / "linux/scripts/01-core/runtime-build-fns.sh"
        chain = ROOT / "linux/scripts/build-cross-chain.sh"
        for (subject, file), missing, selected in itertools.product(
            [
                ("_runtime_timed", runtime),
                ("_chain_disk_watch_start", chain),
                ("_chain_disk_watch_stop", chain),
            ],
            ["parallel_stop_child_advisory", "both"],
            [False, True],
        ):
            with self.subTest(subject=subject, missing=missing, selected=selected):
                code = extract(core, "parallel_require_child_stop")
                code += extract(file, subject)
                code += r"""
set -euo pipefail
is_dry_run() { test "$SELECTED" = 0; }
date() { printf 100; }
log() { :; }
_disk_guard_positive_integer() { return 0; }
_disk_guard_protected_slugs() { :; }
_disk_guard_watch_loop() { printf 'unexpected spawn\n'; }
_runtime_heartbeat() { printf 'unexpected spawn\n'; }
"""
                code += "SELECTED=" + str(int(selected)) + "\n"
                code += 'CROSS_DISK_WATCH="$SELECTED"\n'
                code += '_CHAIN_DISK_WATCH_PID=""\n'
                if selected:
                    code += "_CHAIN_DISK_WATCH_PID=fixture\n"
                if missing == "both":
                    code += "unset -f parallel_require_child_stop\n"
                invocation = subject
                if subject == "_runtime_timed":
                    invocation += " probe arm64 :"
                code += "if " + invocation + "; then r=0; else r=$?; fi\n"
                code += "printf 'status:%s\\n' \"$r\"\n"
                result = subprocess.run(
                    ["bash", "-c", code],
                    capture_output=True,
                    text=True,
                    timeout=10,
                    check=False,
                )
                expected = (127 if missing == "both" else 1) if selected else 0
                self.assertEqual(0, result.returncode)
                self.assertEqual(f"status:{expected}\n", result.stdout)
                if selected:
                    self.assertIn("parallel_", result.stderr)
                else:
                    self.assertEqual("", result.stderr)

    def test_timer_fixture_companion(self):
        code = r"""
source "$1/linux/scripts/tests/test-harness.sh"
source "$1/linux/scripts/tests/runtime-flow-fixtures.sh"
functions="$(runtime_test_timer_sources "$1/linux/scripts" _runtime_timed _runtime_heartbeat)" || exit
eval "$functions" || exit
declare -F parallel_require_child_stop parallel_stop_child_advisory _runtime_timed _runtime_heartbeat
"""
        result = subprocess.run(
            ["bash", "-c", code, "_", str(ROOT)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(
            (
                0,
                "parallel_require_child_stop\nparallel_stop_child_advisory\n_runtime_timed\n_runtime_heartbeat\n",
                "",
            ),
            (result.returncode, result.stdout, result.stderr),
        )

    def test_original_receipts(self):
        expected = json.loads(
            Path(__file__).with_name("runtime-child-stop-receipts.json").read_text()
        )
        self.assertEqual(160, len(expected))
        for row in expected:
            with self.subTest(case=row["case"]):
                self.assertEqual(row["receipt"], receipt(*row["case"]))


if __name__ == "__main__":
    unittest.main()
