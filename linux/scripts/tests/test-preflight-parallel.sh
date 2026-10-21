#!/usr/bin/env bash
# preflight.sh runs its slugs side by side, the tree writers alone, and reports them in registration order.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PREFLIGHT="${TESTS_DIR}/../preflight.sh"
LIB="${TESTS_DIR}/../lib-ordered-jobs.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# By range, not t_fn_src: two of these carry a comment on their opening line.
_FNS="$(grep -E '^PREFLIGHT_(FIRST|LAST)=' "${PREFLIGHT}")"$'\n'
for _fn in _in_csv check_selected _pf_report _pf_run_recorded run_check; do
  _src="$(sed -n "/^${_fn}() {/,/^}/p" "${PREFLIGHT}")"
  [ -n "${_src}" ] || { echo "FAIL: ${_fn} not found in ${PREFLIGHT}" >&2; exit 1; }
  _FNS+="${_src}"$'\n'
done

# _pf <jobs> <body>: the scheduler with stub slugs; each stub logs "start|end <slug> <epoch>" to ${M}.
_pf() {
  printf '%s\n' 'set -uo pipefail
unset PYTHONDONTWRITEBYTECODE
GREEN=""; RED=""; BOLD=""; NC=""
FAILED=(); RAN_CHECKS=0; PREFLIGHT_ONLY=""; PREFLIGHT_SKIP=""; PF_SLUGS=(); PF_NAMES=()
stub() { echo "start $1 $(date +%s)" >> "${M}"; echo "out of $1"; sleep "$2"; echo "end $1 $(date +%s)" >> "${M}"; return "$3"; }' \
    "source $(printf '%q' "${LIB}")" "${_FNS}" "PREFLIGHT_JOBS=$1" "$2" \
    'printf "FAILED=%s\n" "${FAILED[*]}"; echo "PYC=${PYTHONDONTWRITEBYTECODE:-unset}"' > "${_work}/pf.sh"
  : > "${_work}/marks"
  M="${_work}/marks" bash "${_work}/pf.sh" 2>&1
}
_BODY='run_check alpha "alpha check" stub alpha 3 0
run_check mutations "mutation gate" stub mutations 1 0
run_check beta "beta check" stub beta 3 1
run_check cmake-format "cmake-format check" stub cmake-format 1 0
run_check gamma "gamma check" stub gamma 0 0
_pf_run_recorded'
_mark() { sed -n "s/^$1 $2 //p" "${_work}/marks"; }
_order() { printf '%s\n' "$1" | sed -n 's/^== \(.*\) ==$/\1/p' | tr '\n' ',' | sed 's/,$//'; }

t_case "in turn: each slug runs where it is registered, and a red one is collected"
_t0="$(date +%s)"
ser="$(_pf 1 "${_BODY}")"
_ser_secs="$(( $(date +%s) - _t0 ))"
t_assert_contains "${ser}" "FAILED=beta check"
t_assert_eq "alpha check,mutation gate,beta check,cmake-format check,gamma check" "$(_order "${ser}")"
t_assert_contains "${ser}" "PYC=unset"

t_case "side by side: the same report, in registration order, in less time"
_t0="$(date +%s)"
par="$(_pf 8 "${_BODY}")"
t_assert_eq "${ser}" "$(printf '%s\n' "${par}" | sed 's/^PYC=1$/PYC=unset/')" "the report must not depend on the job count"
t_assert_ok test "$(( $(date +%s) - _t0 ))" -le "$(( _ser_secs - 2 ))"
t_assert_contains "${par}" "PYC=1"

t_case "cmake-format ends before any other slug starts, the mutation gate starts after all of them end"
_pf 8 "${_BODY}" > /dev/null
for _s in alpha beta gamma; do
  t_assert_ok test "$(_mark start "${_s}")" -ge "$(_mark end cmake-format)"
  t_assert_ok test "$(_mark start mutations)" -ge "$(_mark end "${_s}")"
done
t_assert_eq "1 1" "$(grep -c 'start cmake-format' "${_work}/marks") $(grep -c 'start mutations' "${_work}/marks")" "each runs once"

t_case "a slug that exits ends itself, never preflight, even when it runs alone"
out="$(_pf 8 'quitter() { exit 3; }
run_check cmake-format "cmake-format check" quitter
run_check alpha "alpha check" stub alpha 0 0
_pf_run_recorded')"
t_assert_contains "${out}" "FAILED=cmake-format check"
t_assert_contains "${out}" "== alpha check =="

t_case "the slug run first builds the venv in the tree; the one run last is the gate that copies the tree"
t_assert_contains "$(sed -n '/^check_cmake_format() {/,/^}/p' "${PREFLIGHT}")" '.venv-cmake-format'
t_assert_contains "$(grep -E "^run_check $(sed -n 's/^PREFLIGHT_FIRST="\(.*\)"$/\1/p' "${PREFLIGHT}") " "${PREFLIGHT}")" "check_cmake_format"
t_assert_contains "$(grep -E "^run_check $(sed -n 's/^PREFLIGHT_LAST="\(.*\)"$/\1/p' "${PREFLIGHT}") " "${PREFLIGHT}")" "docs/scripts/verify_mutations.py"

t_case "the cap holds: two at a time"
_pf 2 'run_check a a stub a 2 0
run_check b b stub b 2 0
run_check c c stub c 2 0
_pf_run_recorded' > /dev/null
t_assert_ok test "$(_mark start c)" -ge "$(( $(_mark start a) + 2 ))"

t_case "the default is one slug per CPU"
t_assert_eq "$(nproc 2>/dev/null || echo 1)" \
  "$(env -u PREFLIGHT_JOBS bash -c "source $(printf '%q' "${LIB}")"$'\n'"$(grep -E '^PREFLIGHT_JOBS=' "${PREFLIGHT}")"$'\n''echo "${PREFLIGHT_JOBS}"')"

t_case "a jobs value that is not a positive integer stops preflight"
for _bad in 0 x; do
  t_assert_eq "2" "$(PREFLIGHT_JOBS="${_bad}" PREFLIGHT_ONLY=crlf-guard bash "${PREFLIGHT}" >/dev/null 2>&1; echo $?)"
done

t_summary
