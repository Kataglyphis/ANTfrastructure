#!/usr/bin/env bash
# Tests for verify_stdout_returns.py. The gate derives its root from its own path
# (parents[2]), so each case copies it into a throwaway tree and plants subject
# scripts under linux/scripts there. Fixture functions are written via printf, so
# this file defines none of them itself.
# docs/code-quality-tooling.md#stdout-return-gate-stdout-returns
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GATE="$(cd "${TESTS_DIR}/.." && pwd)/verify_stdout_returns.py"
PY="${PREFLIGHT_PYTHON:-python3}"
SUBJ="linux/scripts/subject.sh"

# _subject <line-inside-f> [<tail>]: f(), whose stdout is its value, holding
# <line>; <tail> defaults to a command substitution that consumes it.
_subject() { printf 'f() {\n  %s\n  printf "%%s" /opt/x\n}\n%s\n' "$1" "${2-p=\$(f)}"; }
CONSUMER='p=$(f)'

_plant() { mkdir -p "$(dirname "${fix}/$1")"; printf '%s\n' "$2" > "${fix}/$1"; }
# _check <relpath> <content> [<relpath> <content>]: build a tree at the gate's own
# depth, run it, tear it down; leaves ${out} and ${rc} for the asserts.
_check() {
  fix="$(mktemp -d)"
  mkdir -p "${fix}/linux/scripts"
  cp "${GATE}" "${fix}/linux/scripts/"
  _plant "$1" "$2"
  [ $# -le 2 ] || _plant "$3" "$4"
  out="$("${PY}" "${fix}/linux/scripts/verify_stdout_returns.py" 2>&1)"; rc=$?
  rm -rf "${fix}"
}

t_case "a consumed function that logs on stdout is reported, and the run fails"
_check "${SUBJ}" "$(_subject 'log "starting"')"
t_assert_eq "1" "${rc}" "printing a finding is not enough; it must exit non-zero"
t_assert_contains "${out}" "function(s) log on STDOUT"
t_assert_contains "${out}" "linux/scripts/subject.sh: f()"
t_assert_contains "${out}" 'log "starting"' "the offending line is quoted back"

t_case "info() reaches fd 1 too"
_check "${SUBJ}" "$(_subject 'info "starting"')"
t_assert_eq "1" "${rc}"

t_case "the same line redirected to fd 2 is clean"
_check "${SUBJ}" "$(_subject 'log "starting" >&2')"
t_assert_eq "0" "${rc}" ">&2 is the documented fix; the gate must accept it"
t_assert_contains "${out}" "stdout-return gate OK"

t_case "warn/err/die reach fd 2 by construction and are not loggers here"
for _l in warn err die; do
  _check "${SUBJ}" "$(_subject "${_l} \"boom\"")"
  t_assert_eq "0" "${rc}" "${_l} is not a stdout logger"
done

t_case "a function nobody consumes in a substitution may log on stdout"
_check "${SUBJ}" "$(_subject 'log "starting"' 'f')"
t_assert_eq "0" "${rc}" "stdout is not its return value, so a log line breaks nothing"
t_assert_contains "${out}" "stdout-return gate OK"

t_case "the consumer may live in another file"
_check "${SUBJ}" "$(_subject 'log "starting"' ':')" linux/scripts/caller.sh "${CONSUMER}"
t_assert_eq "1" "${rc}" "the substitution set is corpus-wide, not per-file"

t_case "'log' must OPEN the line: the word in argument position is text"
_check "${SUBJ}" "$(_subject 'printf "%s" "see the log file"')"
t_assert_eq "0" "${rc}" "matching mid-line would flag every message that mentions a log"

t_case "the Windows lane is out of scope"
_check linux/scripts/windows/subject.sh "$(_subject 'log "starting"' ':')" \
  linux/scripts/caller.sh "${CONSUMER}"
t_assert_eq "0" "${rc}" "that lane has its own backlog"

t_case "the REAL tree is clean today"
t_assert_eq "0" "$(t_rc "${PY}" "${GATE}")"

t_summary
