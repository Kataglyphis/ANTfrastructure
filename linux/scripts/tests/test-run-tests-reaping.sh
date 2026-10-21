#!/usr/bin/env bash
# run-tests.sh kills each suite's whole process group: after it, on its timeout and when the run itself is interrupted.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_skip_unless "setsid (process groups)" command -v setsid

_WORK="$(mktemp -d)"
trap '_kill_recorded; rm -rf "${_WORK}"' EXIT
mkdir -p "${_WORK}/tests"
cp "${TESTS_DIR}/test-harness.sh" "${TESTS_DIR}/run-tests.sh" "${_WORK}/tests/"
cp "${TESTS_DIR}/../lib-ordered-jobs.sh" "${_WORK}/"

# _suite <name> <body>: a passing suite whose body may leave a child behind, recording its pid in <name>.pid.
_suite() {
  printf '#!/usr/bin/env bash\nsource "$(dirname "$0")/test-harness.sh"\nt_case one\n%s\nt_assert_ok true\nt_summary\n' "$2" \
    > "${_WORK}/tests/$1"
}
_alive() { t_pid_state "$(cat "${_WORK}/$1.pid" 2>/dev/null)"; }
_kill_recorded() { for f in "${_WORK}"/*.pid; do [ -f "${f}" ] && kill -KILL "$(cat "${f}")" 2>/dev/null; done; }
_clear() { _kill_recorded; rm -f "${_WORK}"/tests/test-[a-z]*-*.sh "${_WORK}"/*.pid; }

t_case "a child the suite leaves running is killed when the suite ends"
_suite test-a-leak.sh "sleep 300 & echo \$! > '${_WORK}/leak.pid'"
out="$(bash "${_WORK}/tests/run-tests.sh" </dev/null 2>&1)"
t_assert_contains "${out}" "All linux script test suites passed"
t_assert_eq "dead" "$(_alive leak)" "the leaked sleep outlived its suite"
_clear

t_case "a suite past RUN_TESTS_SUITE_TIMEOUT is killed with its children and fails the run"
_suite test-b-hang.sh "sleep 300 & echo \$! > '${_WORK}/hang.pid'; wait"
out="$(RUN_TESTS_SUITE_TIMEOUT=2 bash "${_WORK}/tests/run-tests.sh" </dev/null 2>&1)"; rc=$?
t_assert_eq "1" "${rc}"
t_assert_contains "${out}" "TIMEOUT: killed after 2s"
t_assert_eq "dead" "$(_alive hang)" "the hung suite's child survived its timeout"
_clear

t_case "a run killed mid-suite takes the running suite's group with it"
_suite test-c-slow.sh "sleep 300 & echo \$! > '${_WORK}/slow.pid'; wait"
bash "${_WORK}/tests/run-tests.sh" </dev/null >/dev/null 2>&1 &
runner=$!
t_wait_file "${_WORK}/slow.pid"
kill -TERM "${runner}"; wait "${runner}" 2>/dev/null
t_assert_eq "dead" "$(_alive slow)" "an interrupted run left its suite's child running"

t_summary
