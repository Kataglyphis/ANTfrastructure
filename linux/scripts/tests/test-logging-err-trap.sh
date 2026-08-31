#!/usr/bin/env bash
# Regression cover for the logging.sh ERR-trap dynamic-scope bug; each case runs
# a real `bash -c`, the only place it reproduces. docs/failure-modes.md
set -uo pipefail

_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/test-harness.sh
source "${_TEST_DIR}/test-harness.sh"

LOGGING_SH="${_TEST_DIR}/../01-core/logging.sh"

# Runs a body in a fresh `bash -c`; sets _OUT (stdout+stderr) and _RC.
# Not a command substitution: a subshell would swallow _RC.
_OUT=""
_RC=0
_run_trap_script() {
  local body="$1"
  local tmp
  tmp="$(mktemp)"
  LOG_COLOR=never NO_COLOR=1 bash -c "
set -Eeuo pipefail
source '${LOGGING_SH}'
${body}
" >"${tmp}" 2>&1
  _RC=$?
  _OUT="$(cat "${tmp}")"
  rm -f "${tmp}"
}

# ── warn trap: reports, does not exit, script runs to completion ──────────────
# The `set +e` window is what makes that observable: under plain `set -e` the
# two traps would be indistinguishable.
t_case "install_warn_trap reports via warn() and lets the script continue"
_run_trap_script '
install_warn_trap
set +e
false
set -e
echo "REACHED-END"
'
t_assert_contains "${_OUT}" "Command failed" "warn trap must report the failure"
t_assert_contains "${_OUT}" "false" "warn trap must name the failing command"
t_assert_contains "${_OUT}" "[WARN]" "warn trap must report at WARN level"
t_assert_contains "${_OUT}" "REACHED-END" "warn trap must not abort the script"
t_assert_eq "0" "${_RC}" "warn trap must not change the exit status"
case "${_OUT}" in
  *"unbound variable"*) t_assert_eq "" "${_OUT}" "warn trap must not die on an unbound variable" ;;
  *) t_assert_eq "0" "0" ;;
esac

# ── err trap: reports at ERROR level and exits 1 ──────────────────────────────
t_case "install_err_trap reports via err() and exits 1"
_run_trap_script '
install_err_trap
set +e
false
set -e
echo "REACHED-END"
'
t_assert_contains "${_OUT}" "Command failed" "err trap must report the failure"
t_assert_contains "${_OUT}" "[ERROR]" "err trap must report at ERROR level"
t_assert_eq "1" "${_RC}" "err trap must exit 1"
case "${_OUT}" in
  *"REACHED-END"*) t_assert_eq "" "${_OUT}" "err trap must abort the script" ;;
  *) t_assert_eq "0" "0" ;;
esac
case "${_OUT}" in
  *"unbound variable"*) t_assert_eq "" "${_OUT}" "err trap must not die on an unbound variable" ;;
  *) t_assert_eq "0" "0" ;;
esac

# ── LINENO/BASH_COMMAND expand at FIRE time, not install time ─────────────────
# Body passed WITHOUT a leading newline: install is line 4, the failing `false`
# line 6. Baking LINENO in at install time would report line 4 forever.
t_case "the trap reports the failing line, not the install site"
_run_trap_script 'install_warn_trap
set +e
false
set -e
echo "REACHED-END"'
t_assert_contains "${_OUT}" "Command failed (line 6): false" "LINENO must expand at fire time"

# ── quoting survives spaces, quotes and $ in the failing command ──────────────
t_case "the reported command survives spaces, quotes and \$"
_run_trap_script '
install_warn_trap
set +e
grep -q "no such $HOME pattern '"'"'x'"'"'" /dev/null
set -e
echo "REACHED-END"
'
t_assert_contains "${_OUT}" "Command failed" "quoted command must still be reported"
t_assert_contains "${_OUT}" "grep -q" "the failing command must appear verbatim"
t_assert_contains "${_OUT}" "REACHED-END" "quoting must not abort the warn-trap script"

# ── installed from inside a function, fires at top level ──────────────────────
t_case "a trap installed inside a function still fires at top level"
_run_trap_script '
setup() { install_warn_trap; }
setup
set +e
false
set -e
echo "REACHED-END"
'
t_assert_contains "${_OUT}" "Command failed" "installer frame must not be needed at fire time"
t_assert_contains "${_OUT}" "[WARN]" "action must survive the installer returning"
t_assert_contains "${_OUT}" "REACHED-END" "warn trap must still not abort"

# ── fires from inside a different function (errtrace) ─────────────────────────
t_case "the trap fires from inside another function"
_run_trap_script '
install_warn_trap
boom() { set +e; false; set -e; }
boom
echo "REACHED-END"
'
t_assert_contains "${_OUT}" "Command failed" "ERR trap must fire inside functions under -E"
t_assert_contains "${_OUT}" "[WARN]" "action must resolve inside a foreign function frame"
t_assert_contains "${_OUT}" "REACHED-END" "warn trap must not abort from a function"

# ── both traps installed, either order: the last install wins ─────────────────
t_case "install_err_trap then install_warn_trap ends up with warn semantics"
_run_trap_script '
install_err_trap
install_warn_trap
set +e
false
set -e
echo "REACHED-END"
'
t_assert_contains "${_OUT}" "[WARN]" "last install must win"
t_assert_contains "${_OUT}" "REACHED-END" "warn semantics must not exit"
t_assert_eq "0" "${_RC}" "warn semantics must keep the exit status"

t_case "install_warn_trap then install_err_trap ends up with err semantics"
_run_trap_script '
install_warn_trap
install_err_trap
set +e
false
set -e
echo "REACHED-END"
'
t_assert_contains "${_OUT}" "[ERROR]" "last install must win"
t_assert_eq "1" "${_RC}" "err semantics must exit 1"

# ── build-gcc.sh re-arms the BARE two-argument trap by hand ───────────────────
# It must keep the installed err semantics; see docs/failure-modes.md
t_case "a hand-re-armed bare on_err trap keeps the installed action"
_run_trap_script '
install_err_trap
trap - ERR
false || true
trap '"'"'on_err "${LINENO}" "${BASH_COMMAND}"'"'"' ERR
set +e
false
set -e
echo "REACHED-END"
'
t_assert_contains "${_OUT}" "Command failed" "bare re-arm must still report"
t_assert_contains "${_OUT}" "[ERROR]" "bare re-arm must keep err semantics"
t_assert_eq "1" "${_RC}" "bare re-arm must still exit 1"
case "${_OUT}" in
  *"unbound variable"*) t_assert_eq "" "${_OUT}" "bare re-arm must not die on an unbound variable" ;;
  *) t_assert_eq "0" "0" ;;
esac

t_summary
