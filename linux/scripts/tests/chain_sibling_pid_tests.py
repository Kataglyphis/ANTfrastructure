"""Offline PID receipts stub kill and file reads; no real process is signalled and no chain is started."""

import json
import pathlib
import re
import subprocess
import sys
import tempfile

CHAIN = pathlib.Path(sys.argv[1]).resolve()
TESTS = pathlib.Path(__file__).parent


WORKER = r"""
set -u
work="$1" operation="$2" shape="$3" content="$4" kill_rc="$5" context="$6" strict="$7"
builtin printf '%s' "$$" > "$work/self"
source "$work/functions"
case "$content" in SELF) content="$$";; esac
case "$shape" in file) builtin printf '%s' "$content" > "$work/pid";; dir) mkdir "$work/pid";; esac
cross_chain_pidfile_path() { builtin printf '%s' "$work/pid"; }
cat() { builtin printf 'CAT:<%s>\n' "$*" >> "$work/trace"; builtin printf '%s' "$content"; return 0; }
kill() { builtin printf 'KILL:<%s>\n' "$*" >> "$work/trace"; return "$kill_rc"; }
warn() { builtin printf 'WARN:%s\n' "$*"; }
_CHAIN_PIDFILE=before
snapshot() { builtin printf 'PIDFILE:<%s>\n' "$_CHAIN_PIDFILE" > "$work/state"; if [[ -f "$work/pid" ]]; then command cat "$work/pid" >> "$work/state"; fi; }
trap snapshot EXIT
if [[ "$strict" = strict ]]; then set -e; fi
if [[ "$context" = conditional ]]; then
 if "$operation"; then status=0; else status=$?; fi
else "$operation"; status=$?; fi
builtin printf 'TAIL:%s\n' "$status"
"""


def predicate_controls(definitions):
    worker = r"""
source "$1"
pid="$2" status="$3"
[[ "$pid" != SELF ]] || pid="$$"
kill() { printf 'KILL:<%s>\n' "$*"; printf 'hidden probe diagnostic\n' >&2; return "$status"; }
if _chain_is_live_other_pid "$pid"; then rc=0; else rc=$?; fi
printf 'RESULT:%s\n' "$rc"
"""
    with tempfile.TemporaryDirectory(prefix="ant pid controls ") as directory:
        functions = pathlib.Path(directory) / "functions"
        functions.write_text(definitions)
        for pid in ("", "SELF", "12345"):
            for status in (0, 1, 7):
                result = subprocess.run(
                    [
                        "bash",
                        "-eu",
                        "-c",
                        worker,
                        "_",
                        str(functions),
                        pid,
                        str(status),
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                    timeout=5,
                )
                expected = (
                    f"KILL:<-0 12345>\nRESULT:{status}\n"
                    if pid == "12345"
                    else "RESULT:1\n"
                )
                assert result.returncode == 0, (pid, status, result)
                assert result.stdout == expected, (pid, status, result.stdout)
                assert result.stderr == "", (pid, status, result.stderr)
    return 27


def main():
    names = (
        "_chain_is_live_other_pid",
        "_chain_live_sibling_pid",
        "_chain_write_pidfile",
    )
    definitions = subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; shift; for name in "${@:2}"; do t_fn_src "$1" "$name" || exit; done',
            "_",
            str(TESTS / "test-harness.sh"),
            str(CHAIN),
            *names,
        ],
        capture_output=True,
        text=True,
        check=True,
        timeout=5,
    ).stdout
    frozen = json.loads((TESTS / "chain-sibling-pid-receipts.json").read_text())
    assertions = predicate_controls(definitions)
    for row in frozen["cases"]:
        with tempfile.TemporaryDirectory(prefix="ant pid ") as directory:
            work = pathlib.Path(directory)
            (work / "functions").write_text(definitions)
            (work / "trace").write_text("")
            result = subprocess.run(
                ["bash", "-c", WORKER, "_", directory, *map(str, row["case"])],
                capture_output=True,
                check=False,
                timeout=5,
            )

            def clean(data, work=work):
                data = re.sub(
                    r": line \d+:",
                    ": line [LINE]:",
                    data.decode().replace(directory, "[WORK]"),
                )
                return re.sub(
                    r"(?<!\d)" + (work / "self").read_text() + r"(?!\d)", "[PID]", data
                )

            actual = {
                "rc": result.returncode,
                "out": clean(result.stdout),
                "err": clean(result.stderr),
                "trace": clean((work / "trace").read_bytes()),
                "state": clean((work / "state").read_bytes()),
            }
            for field, expected in row["receipt"].items():
                if field != "rc":
                    expected = frozen["strings"][expected]
                assert actual[field] == expected, (
                    row["case"],
                    field,
                    expected,
                    actual[field],
                )
                assertions += 1
    print(
        f"PASS: {len(frozen['cases'])} original PID receipts; {assertions} assertions"
    )


if __name__ == "__main__":
    main()
