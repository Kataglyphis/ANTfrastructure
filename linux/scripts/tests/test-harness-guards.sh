#!/usr/bin/env bash
# A message passed to t_assert_ok/t_assert_fails would pass vacuously; see docs/cross-build-verification.md#the-linuxscriptstests-suites
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

# One harness run in its own shell, so its counters never touch ours.
_harness() {
  bash -c '
    source "'"${TESTS_DIR}"'/test-harness.sh"
    t_case inner
    '"$1"'
    t_summary' 2>&1
}

t_case "a well-formed assertion still passes and still fails"
t_assert_contains "$(_harness 't_assert_ok test -f "${_T_SCRIPTS}/tests/test-harness.sh"')" "1 assertion(s) passed"
t_assert_contains "$(_harness 't_assert_fails test -f /definitely/not/here')" "1 assertion(s) passed"
t_assert_contains "$(_harness 't_assert_ok test -f /definitely/not/here')" "expected success"
t_assert_contains "$(_harness 't_assert_fails test -f "${_T_SCRIPTS}/tests/test-harness.sh"')" "expected failure"

t_case "a message passed to t_assert_fails is caught, not counted as a failure"
_out="$(_harness 't_assert_fails test -f "${_T_SCRIPTS}/tests/test-harness.sh" "the message"')"
t_assert_contains "${_out}" "malformed test expression" \
  "test -f X msg exits 2 -- 'not zero', which reads as the failure the case wanted"
t_assert_contains "${_out}" "takes a COMMAND and no message"
t_assert_contains "${_out}" "t_assert_fails takes" "the message must name the assertion that was misused"
t_assert_contains "${_out}" "1 assertion(s) FAILED" "a vacuous pass is the whole defect"

t_case "the same trap on t_assert_ok is caught too"
_out="$(_harness 't_assert_ok test -f "${_T_SCRIPTS}/tests/test-harness.sh" "the message"')"
t_assert_contains "${_out}" "malformed test expression"
t_assert_contains "${_out}" "t_assert_ok takes"

t_case "only test/[ report a usage error, so nothing else is second-guessed"
# A command that legitimately exits 2 is judged on its exit code, not turned into a harness complaint.
t_assert_contains "$(_harness 't_assert_fails bash -c "exit 2"')" "1 assertion(s) passed" \
  "exit 2 from a real command is a real failure"
t_assert_contains "$(_harness 't_assert_ok bash -c "exit 0"')" "1 assertion(s) passed"

_tmp="$(mktemp -d)"
trap 'rm -rf "${_tmp}"' EXIT

t_case "t_assert_rc holds the exact exit code"
t_assert_contains "$(_harness 't_assert_rc 2 bash -c "exit 2"')" "1 assertion(s) passed"
_out="$(_harness 't_assert_rc 1 bash -c "echo usage: x; exit 2"')"
t_assert_contains "${_out}" "expected rc 1, got 2"
t_assert_contains "${_out}" "usage: x"
t_assert_contains "$(_harness 't_assert_rc 0 false')" "1 assertion(s) FAILED"

t_case "t_assert_grep and t_assert_no_grep read the file, a miss shows it, and a pattern may start with --"
printf 'alpha
beta 42
--flag
' > "${_tmp}/out"
t_assert_contains "$(_harness "t_assert_grep '${_tmp}/out' '^beta [0-9]+\$'")" "1 assertion(s) passed"
_out="$(_harness "t_assert_grep '${_tmp}/out' '^gamma'")"
t_assert_contains "${_out}" "no /^gamma/ in ${_tmp}/out"
t_assert_contains "${_out}" "alpha"
t_assert_contains "$(_harness "t_assert_grep '${_tmp}/out' '--flag'")" "1 assertion(s) passed"
t_assert_contains "$(_harness "t_assert_no_grep '${_tmp}/out' '^gamma'")" "1 assertion(s) passed"
t_assert_contains "$(_harness "t_assert_no_grep '${_tmp}/out' 'beta'")" "unexpected /beta/"
t_assert_contains "$(_harness "t_assert_no_grep '${_tmp}/missing' 'beta'")" "cannot read ${_tmp}/missing"

t_case "a consumer's suite sources lib/test-harness.sh from its own tree, and t_summary decides its exit"
mkdir -p "${_tmp}/consumer/scripts/linux/tests"
# consumer_suite <assertions>: a consumer-shaped suite that sources the hub's lib entry; prints its output and exit code.
consumer_suite() {
  printf '#!/usr/bin/env bash
set -u
source "%s/lib/test-harness.sh"
t_case one
%s
t_summary
' "${_T_SCRIPTS}" "$1"     > "${_tmp}/consumer/scripts/linux/tests/test-x.sh"
  (cd "${_tmp}/consumer" && bash scripts/linux/tests/test-x.sh 2>&1; echo "rc=$?")
}
_out="$(consumer_suite 't_assert_rc 0 true')"
t_assert_contains "${_out}" "1 assertion(s) passed"
t_assert_contains "${_out}" "rc=0"
t_assert_contains "$(consumer_suite 't_assert_eq 1 2')" "rc=1"
t_assert_contains "$(consumer_suite ':')" "ZERO ASSERTIONS"

t_case "Python CI fixtures preserve paths and requested source bytes without workspace side effects"
fixture_sources="${_tmp}/fixture sources"
mkdir -p "${fixture_sources}/01-core" "${fixture_sources}/extra"
printf 'fixture_uv_loaded=1\n' > "${fixture_sources}/01-core/python_uv.sh"
printf 'fixture logging\n' > "${fixture_sources}/01-core/logging.sh"
printf 'fixture driver\n' > "${fixture_sources}/extra/driver.sh"
t_assert_ok t_python_ci_fixture "${_tmp}/python fixture" "${fixture_sources}" extra/driver.sh
t_assert_eq "${_tmp}/python fixture/ws" "${WS}"
t_assert_eq "${_tmp}/python fixture/tree" "${TREE}"
t_assert_eq "${_tmp}/python fixture/calls" "${CALLS}"
t_assert_eq "${_tmp}/python fixture/out" "${OUT}"
t_assert_eq "${_tmp}/python fixture/bin" "${BIN}"
t_assert_ok test -d "${WS}"
t_assert_ok test -d "${BIN}"
for relative in 01-core/python_uv.sh 01-core/logging.sh extra/driver.sh; do
  t_assert_ok cmp "${fixture_sources}/${relative}" "${TREE}/${relative}"
done
t_assert_eq "1|${WS}" "$(FIXTURE_WS="${WS}" bash -c 'source "$1"; detect_workspace; printf "%s|%s" "$fixture_uv_loaded" "$WORKSPACE_ROOT"' _ "${TREE}/02-toolchain/python/ci-common.sh")"
t_assert_fails t_python_ci_fixture "${_tmp}/missing source fixture" "${fixture_sources}" extra/missing.sh

t_summary
