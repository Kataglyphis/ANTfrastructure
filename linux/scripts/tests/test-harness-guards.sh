#!/usr/bin/env bash
# The harness's own guard. t_assert_ok and t_assert_fails take a COMMAND and no
# message, so `t_assert_fails test -f X "why"` runs `test -f X why` -- it fails
# for the WRONG reason and passes vacuously. Four of those were written and
# caught by review in one wave; nothing in the harness caught them.
# docs/cross-build-verification.md#the-linuxscriptstests-suites
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
t_assert_contains "$(_harness 't_assert_ok test -f /etc/passwd')" "1 assertion(s) passed"
t_assert_contains "$(_harness 't_assert_fails test -f /definitely/not/here')" "1 assertion(s) passed"
t_assert_contains "$(_harness 't_assert_ok test -f /definitely/not/here')" "expected success"
t_assert_contains "$(_harness 't_assert_fails test -f /etc/passwd')" "expected failure"

t_case "a message passed to t_assert_fails is caught, not counted as a failure"
_out="$(_harness 't_assert_fails test -f /etc/passwd "the message"')"
t_assert_contains "${_out}" "malformed test expression" \
  "test -f X msg exits 2 -- 'not zero', which reads as the failure the case wanted"
t_assert_contains "${_out}" "takes a COMMAND and no message"
t_assert_contains "${_out}" "t_assert_fails takes" "the message must name the assertion that was misused"
t_assert_contains "${_out}" "1 assertion(s) FAILED" "a vacuous pass is the whole defect"

t_case "the same trap on t_assert_ok is caught too"
_out="$(_harness 't_assert_ok test -f /etc/passwd "the message"')"
t_assert_contains "${_out}" "malformed test expression"
t_assert_contains "${_out}" "t_assert_ok takes"

t_case "only test/[ report a usage error, so nothing else is second-guessed"
# A command that legitimately exits 2 must be judged on its exit code, not
# rewritten into a harness complaint.
t_assert_contains "$(_harness 't_assert_fails bash -c "exit 2"')" "1 assertion(s) passed" \
  "exit 2 from a real command is a real failure"
t_assert_contains "$(_harness 't_assert_ok bash -c "exit 0"')" "1 assertion(s) passed"

t_summary
