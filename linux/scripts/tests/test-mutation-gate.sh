#!/usr/bin/env bash
# Tests for docs/scripts/verify_mutations.py. It edits files IN PLACE to check a
# test can fail, so the case that matters most is that it always puts them back.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
REPO="$(cd "${TESTS_DIR}/../../.." && pwd)"
PY="${PREFLIGHT_PYTHON:-python3}"
GATE="${REPO}/docs/scripts/verify_mutations.py"

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT

# A subject with one guard, a test that may or may not look at it, and a manifest
# naming one mutation. Written with printf: a nested heredoc here was the first
# thing to go wrong.
_fixture() {
  local find="$1" replace="$2" test_checks="$3"
  printf 'GUARD=on\n' > "${_work}/subject.sh"
  if [ "${test_checks}" = "yes" ]; then
    printf 'grep -q "GUARD=on" "%s/subject.sh"\n' "${_work}" > "${_work}/t.sh"
  else
    printf 'true\n' > "${_work}/t.sh"      # a test that cannot fail
  fi
  printf '[{"id":"probe","target":"subject.sh","find":"%s","replace":"%s","test":"bash %s/t.sh","why":"probe"}]\n' \
    "${find}" "${replace}" "${_work}" > "${_work}/m.json"
}

_run() { "${PY}" "${GATE}" --manifest "${_work}/m.json" --root "${_work}" 2>&1; }
_rc()  { "${PY}" "${GATE}" --manifest "${_work}/m.json" --root "${_work}" >/dev/null 2>&1; echo $?; }

t_case "a mutation the tests catch is reported as biting"
_fixture "GUARD=on" "GUARD=off" yes
t_assert_contains "$(_run)" "bites" "the guarded test must go red"
t_assert_eq "0" "$(_rc)" "a caught mutation is the healthy case"

t_case "a mutation the tests SURVIVE is the whole point, and fails the gate"
_fixture "GUARD=on" "GUARD=off" no
_out="$(_run)"
t_assert_contains "${_out}" "SURVIVED" "a test that passes without the guard must be named"
# The message is not the contract: it has to EXIT non-zero, or CI stays green on
# a vacuous test. Naming the problem and passing anyway is the failure mode this
# whole tool exists to find.
t_assert_eq "1" "$(_rc)" "a surviving mutation must fail the gate, not just print"
t_assert_contains "${_out}" "guarantee removed" "the message must say what it means"

t_case "a stale find string fails instead of silently doing nothing"
_fixture "GUARD=nowhere" "x" yes
t_assert_contains "$(_run)" "stale" "a mutation that no longer applies is dead"
t_assert_eq "1" "$(_rc)" "a stale mutation must fail too -- it is silently testing nothing"

t_case "the target is restored afterwards, whatever the verdict"
_fixture "GUARD=on" "GUARD=off" yes
_run >/dev/null 2>&1
t_assert_eq "GUARD=on" "$(cat "${_work}/subject.sh")" \
  "a tool that edits in place must never leave the tree mutated"

t_summary
