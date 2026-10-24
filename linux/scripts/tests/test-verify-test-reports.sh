#!/usr/bin/env bash
# A green test command must carry a nonempty JUnit run and measured package coverage.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CHECK="${TESTS_DIR}/../02-toolchain/python/verify-test-reports.py"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
_junit="${_work}/junit.xml"
_coverage="${_work}/coverage.xml"

_run() { python3 -I "${CHECK}" --junit "${_junit}" --coverage "${_coverage}" "$@"; }
_good_junit() { printf '<testsuite tests="2" failures="0" errors="0"><testcase name="pass"/><testcase name="skip"><skipped/></testcase></testsuite>\n' > "${_junit}"; }
_good_coverage() { printf '<coverage lines-valid="10" lines-covered="7"/>\n' > "${_coverage}"; }

t_case "a real passing test and covered package lines satisfy the report contract"
_good_junit; _good_coverage
t_assert_eq 0 "$(t_rc _run --min-coverage 70)"
t_assert_contains "$(t_out _run)" "1 passed; package coverage 70.00%"

t_case "the caller's line coverage floor is enforced"
t_assert_eq 1 "$(t_rc _run --min-coverage 70.01)"
t_assert_contains "$(t_out _run --min-coverage 70.01)" "below the 70.01% floor"

t_case "an invalid coverage floor is a configuration error"
t_assert_eq 1 "$(t_rc _run --min-coverage 101)"
t_assert_eq 1 "$(t_rc _run --min-coverage nan)"

t_case "a missing, empty, or malformed JUnit report cannot pass"
rm -f "${_junit}"
t_assert_eq 1 "$(t_rc _run)"
printf '<testsuite tests="0"/>' > "${_junit}"
t_assert_eq 1 "$(t_rc _run)"
printf '<testsuite' > "${_junit}"
t_assert_eq 1 "$(t_rc _run)"

t_case "an all-skipped run is not a test verdict"
printf '<testsuite tests="1"><testcase name="skip"><skipped/></testcase></testsuite>\n' > "${_junit}"
t_assert_eq 1 "$(t_rc _run)"

t_case "a failing case or a JUnit failure count cannot pass"
printf '<testsuite tests="1"><testcase name="fail"><failure/></testcase></testsuite>\n' > "${_junit}"
t_assert_eq 1 "$(t_rc _run)"
printf '<testsuite tests="1" failures="1"><testcase name="pass"/></testsuite>\n' > "${_junit}"
t_assert_eq 1 "$(t_rc _run)"

t_case "an empty or wrong-target coverage report cannot pass"
_good_junit
rm -f "${_coverage}"
t_assert_eq 1 "$(t_rc _run)"
printf '<coverage lines-valid="0" lines-covered="0"/>\n' > "${_coverage}"
t_assert_eq 1 "$(t_rc _run)"
printf '<coverage lines-valid="10" lines-covered="0"/>\n' > "${_coverage}"
t_assert_eq 1 "$(t_rc _run)"

t_summary
