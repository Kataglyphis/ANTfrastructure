"""Frozen handler receipts cover shell state offline; no orchestrator main, build or engine is executed."""

import json
import pathlib
import re
import subprocess
import sys
import tempfile

SCRIPTS = pathlib.Path(sys.argv[1]).resolve()
TESTS = pathlib.Path(__file__).parent


def function(leaf, name):
    result = subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; t_fn_src "$2" "$3"',
            "_",
            str(TESTS / "test-harness.sh"),
            str(SCRIPTS / leaf),
            name,
        ],
        capture_output=True,
        text=True,
        check=True,
        timeout=5,
    )
    return result.stdout


WORKER = r'''
set -u
WORK="$1" caller="$2" profile="$3" value="$4" context="$5" strict="$6" argv_mode="$7"
source "$WORK/functions"
unset LOG_DIR _OARG_SHIFT target arr assoc hop index _oct_targets _shift_target
case "$profile" in
 unset) : ;;
 plain) LOG_DIR=old ;;
 empty) LOG_DIR='' ;;
 exported) export LOG_DIR=old ;;
 exported-unset) export LOG_DIR ;;
 readonly) readonly LOG_DIR=old ;;
 readonly-unset) readonly LOG_DIR ;;
 array) declare -a LOG_DIR=(old keep) ;;
 integer) declare -i LOG_DIR=7 ;;
 nameref) target=old; declare -n LOG_DIR=target ;;
 nameref-unset) declare -n LOG_DIR=target ;;
 nameref-chain) target=old; declare -n hop=target LOG_DIR=hop ;;
 nameref-readonly-target) readonly target=old; declare -n LOG_DIR=target ;;
 readonly-nameref) target=old; declare -rn LOG_DIR=target ;;
 nameref-array) declare -a arr=(zero old keep); declare -n LOG_DIR='arr[1]' ;;
 nameref-index) declare -a arr=(zero one two three four); index=1; declare -n LOG_DIR='arr[index++]' ;;
 nameref-assoc) declare -A assoc=([key]=old [other]=keep); declare -n LOG_DIR='assoc[key]' ;;
 nameref-positional) declare -a arr=(zero one two); declare -n LOG_DIR='arr[$2]' ;;
 shift-positional) LOG_DIR=old; declare -a arr=(zero one two); declare -n _OARG_SHIFT='arr[$2]' ;;
 nameref-count) declare -a arr=(zero one two); declare -n LOG_DIR='arr[$#]' ;;
 shift-count) LOG_DIR=old; declare -a arr=(zero one two); declare -n _OARG_SHIFT='arr[$#]' ;;
 nameref-third) declare -a arr=(zero one two); declare -n LOG_DIR='arr[$3]' ;;
 cross-oct) _oct_targets=old; declare -n LOG_DIR=_oct_targets ;;
 cross-oct-array) declare -a _oct_targets=(old keep); declare -n LOG_DIR='_oct_targets[0]' ;;
 cross-shift) _OARG_SHIFT=7; declare -n LOG_DIR=_OARG_SHIFT ;;
 shift-plain) LOG_DIR=old; _OARG_SHIFT=7 ;;
 shift-exported) LOG_DIR=old; export _OARG_SHIFT=7 ;;
 shift-readonly) LOG_DIR=old; readonly _OARG_SHIFT=7 ;;
 shift-readonly-unset) LOG_DIR=old; readonly _OARG_SHIFT ;;
 shift-nameref) LOG_DIR=old; _shift_target=7; declare -n _OARG_SHIFT=_shift_target ;;
 shift-cross) LOG_DIR=old; declare -n _OARG_SHIFT=LOG_DIR ;;
 shift-oct) LOG_DIR=old; _oct_targets=7; declare -n _OARG_SHIFT=_oct_targets ;;
 oct-readonly) LOG_DIR=old; readonly _oct_targets=private ;;
 oct-exported) LOG_DIR=old; export _oct_targets=private ;;
esac
snapshot() {
 declare -p LOG_DIR _OARG_SHIFT target arr assoc hop index _shift_target > "$WORK/state" 2>/dev/null || :
 case "$profile" in cross-oct|cross-oct-array|shift-oct|oct-readonly|oct-exported) declare -p _oct_targets >> "$WORK/state" 2>/dev/null || : ;; esac
}
trap snapshot EXIT
case "$argv_mode" in
 value) args=(--log-dir "$value") ;;
 trailing) args=(--log-dir "$value" --stage base) ;;
 flag) args=(--log-dir) ;;
 none) args=() ;;
 unknown) args=(--not-an-option "$value") ;;
esac
if [[ "$strict" = strict ]]; then set -e; fi
operation() { if [[ "$caller" = stage ]]; then _cross_stage_extra_arg "${args[@]}"; else _chain_extra_arg "${args[@]}"; fi; }
if [[ "$context" = conditional ]]; then
 if operation; then status=0; else status=$?; fi
else operation; status=$?; fi
builtin printf 'TAIL:%s\n' "$status"
'''


def main():
    frozen = json.loads((TESTS / "log-dir-consumer-receipts.json").read_text())
    definitions = "\n".join(
        function(leaf, name)
        for leaf, name in (
            ("build-cross-stage.sh", "_cross_stage_extra_arg"),
            ("build-cross-chain.sh", "_chain_extra_arg"),
            ("lib-orchestrator.sh", "orchestrator_consume_log_dir"),
        )
    )
    assertions = 0
    for row in frozen["cases"]:
        with tempfile.TemporaryDirectory(prefix="ant log dir ") as directory:
            work = pathlib.Path(directory)
            (work / "functions").write_text(definitions)
            result = subprocess.run(
                ["bash", "-c", WORKER, "_", directory, *row["case"]],
                capture_output=True,
                check=False,
                timeout=5,
            )

            def clean(value):
                return re.sub(
                    r": line [0-9]+:",
                    ": line [LINE]:",
                    value.decode().replace(directory, "[WORK]"),
                )

            actual = {
                "rc": result.returncode,
                "out": clean(result.stdout),
                "err": clean(result.stderr),
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
        f"PASS: {len(frozen['cases'])} original handler receipts; {assertions} assertions"
    )


if __name__ == "__main__":
    main()
