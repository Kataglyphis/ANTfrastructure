"""Actual wheel and packaging callers retain callback configuration; subprocess tools never install or strip anything."""

import itertools
import os
import pathlib
import subprocess
import sys
import tempfile

SCRIPTS = pathlib.Path(sys.argv[1]).resolve()
TESTS = pathlib.Path(__file__).parent
SOURCES = {
    "01-core/common.sh": ["wheel_archive_run"],
    "03-media/build/litert/litert-wheel.sh": ["_litert_fix_pywrap_ext_name"],
    "03-media/runtime/repair-wheels.sh": ["_repair_wheel_uv", "strip_cross_wheels"],
    "02-toolchain/packaging-deps.sh": [
        "best_effort_mode",
        "_packaging_execute",
        "_packaging_step_failure",
        "run_step",
        "_packaging_sudo_failure",
        "try_or_sudo",
    ],
}
WORKER = r"""
set -eu
source "$1/functions"
root="$1" family="$2" scope="$3" callback_status="$4"
action=GLOBAL_ACTION source=GLOBAL_SOURCE destination=GLOBAL_DESTINATION failure_handler=GLOBAL_HANDLER
provided_command() {
  printf '%s|%s|%s|%s\n' "$action" "$source" "$destination" "$failure_handler" >> "$root/trace"
  return "$callback_status"
}
provided_python() { provided_command; }
uv() { provided_command; }
sudo() { provided_command; }
_resolve_media_strip_bin() { printf 'never-used-strip'; }
first_match() { return 0; }
warn() { :; }
info() { :; }
exercise() {
  case "$family" in
    litert) _litert_fix_pywrap_ext_name ;;
    repair) strip_cross_wheels ;;
    step) run_step LABEL provided_command ;;
    retry) try_or_sudo provided_command ;;
  esac
}
caller() {
  if [[ "$scope" = local ]]; then
    local action=LOCAL_ACTION source=LOCAL_SOURCE destination=LOCAL_DESTINATION failure_handler=LOCAL_HANDLER
  fi
  if exercise; then result=0; else result=$?; fi
  printf 'RESULT:%s\n' "$result"
}
LITERT_PREFIX="$root/litert" WHEELS_DIR="$root/repair" PYTHON=provided_python PACKAGING_DEPS_MODE=strict
mkdir -p "$LITERT_PREFIX/wheels" "$WHEELS_DIR"
: > "$LITERT_PREFIX/wheels/ai_edge_litert-test.whl"
: > "$WHEELS_DIR/test-linux.whl"
caller
cat "$root/trace"
"""


ALIAS_WORKER = r"""set -eu
shopt -s expand_aliases
root="$1" phase="$2" scope="$3" outcome="$4" prefix_alias="${5:-none}"
action=GLOBAL_ACTION source=GLOBAL_SOURCE destination=GLOBAL_DESTINATION
run_fake_wheel() {
  printf '%s:%s:%s|%s|%s\n' "$1" "$6" "$action" "$source" "$destination" >> "$root/trace"
  [[ "$outcome" != fail ]] || return 13
  case "$6" in
    unpack) mkdir -p "${9}/dist"; printf SO > "${9}/dist/payload.so" ;;
    pack) printf PACKED > "${9}/rebuilt.whl" ;;
  esac
}
uv() { [[ "$#" -eq 8 ]] || return 92; run_fake_wheel DYNAMIC "$@"; }
provided_alias() {
 [[ "$#" -eq 8 ]] || return 95
 run_fake_wheel ALIAS "$@"
}
if [[ "$phase" = before ]]; then
 if [[ "$prefix_alias" = yes ]]; then alias uv='provided_alias "$@"'; else alias uv=provided_alias; fi
fi
source "$root/functions"
if [[ "$phase" = after ]]; then alias uv=provided_alias; else alias uv=never_called_later_alias; fi
_resolve_media_strip_bin() { printf never-used-strip; }
apply_shared_library_action() { printf 'STRIP\n' >> "$root/trace"; }
first_match() { find "$@" -print -quit; }
WHEELS_DIR="$root/wheels"
mkdir "$WHEELS_DIR"
printf ORIGINAL > "$WHEELS_DIR/test-linux.whl"
caller() {
 if [[ "$scope" = local ]]; then local action=LOCAL_ACTION source=LOCAL_SOURCE destination=LOCAL_DESTINATION; fi
 strip_cross_wheels
}
caller
cat "$root/trace"
for artifact in "$WHEELS_DIR"/*; do printf 'ARTIFACT:%s:' "${artifact##*/}"; cat "$artifact"; printf '\n'; done
"""


def alias_controls(definitions):
    checks = 0
    for phase, scope, outcome, prefix_alias in itertools.product(
        ("before", "after"),
        ("global", "local"),
        ("success", "fail"),
        ("none", "yes"),
    ):
        with tempfile.TemporaryDirectory(prefix="ant wheel alias ") as directory:
            root = pathlib.Path(directory)
            (root / "functions").write_text(definitions)
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    ALIAS_WORKER,
                    "_",
                    directory,
                    phase,
                    scope,
                    outcome,
                    prefix_alias,
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=5,
            )
            selected = "ALIAS" if phase == "before" else "DYNAMIC"
            prefix = scope.upper()
            state = f"{prefix}_ACTION|{prefix}_SOURCE|{prefix}_DESTINATION"
            expected = f"{selected}:unpack:{state}\n"
            if outcome == "success":
                expected = "  AP1: stripped + repacked rebuilt.whl\n" + expected
                expected += (
                    f"STRIP\n{selected}:pack:{state}\nARTIFACT:rebuilt.whl:PACKED\n"
                )
            else:
                expected += "ARTIFACT:test-linux.whl:ORIGINAL\n"
            assert result.returncode == 0, (phase, scope, outcome, result)
            assert result.stderr == "", (phase, scope, outcome, result.stderr)
            assert result.stdout == expected, (
                phase,
                scope,
                outcome,
                result.stdout,
            )
            checks += 3
    return checks


def main():
    chunks = []
    for leaf, names in SOURCES.items():
        extraction = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; t_source_functions "$2" "${@:3}" || exit; declare -f "${@:3}"',
                "_",
                str(TESTS / "test-harness.sh"),
                str(SCRIPTS / leaf),
                *names,
            ],
            capture_output=True,
            text=True,
            check=True,
            timeout=5,
        )
        chunks.append(extraction.stdout)
    checks = alias_controls("\n".join(chunks))
    for family in ("litert", "repair", "step", "retry"):
        for scope in ("global", "local"):
            for status in (0, 13):
                with tempfile.TemporaryDirectory(
                    prefix="ant callback scope "
                ) as directory:
                    root = pathlib.Path(directory)
                    (root / "functions").write_text("\n".join(chunks))
                    result = subprocess.run(
                        [
                            "bash",
                            "-c",
                            WORKER,
                            "_",
                            directory,
                            family,
                            scope,
                            str(status),
                        ],
                        capture_output=True,
                        text=True,
                        check=False,
                        timeout=5,
                    )
                    prefix = scope.upper()
                    line = f"{prefix}_ACTION|{prefix}_SOURCE|{prefix}_DESTINATION|{prefix}_HANDLER\n"
                    rc = status if family in ("step", "retry") else 0
                    # A non-root sudo retry repeats the same command with unchanged wrapper configuration.
                    repeats = (
                        2 if family == "retry" and status and os.geteuid() != 0 else 1
                    )
                    assert result.returncode == 0, (family, scope, status, result)
                    assert result.stderr == "", (family, scope, status, result.stderr)
                    assert result.stdout == f"RESULT:{rc}\n" + line * repeats, (
                        family,
                        scope,
                        status,
                        result.stdout,
                    )
                    checks += 3
    print(f"PASS: 32 actual caller scope/alias cases, {checks} assertions")


if __name__ == "__main__":
    main()
