#!/usr/bin/env bash
# cargo-test-junit.py over recorded cargo test logs, and cargo_test.sh writing log and JUnit with cargo's own status.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
RUST_DIR="$(cd "${TESTS_DIR}/../02-toolchain/rust" && pwd)"
fixtures="${TESTS_DIR}/fixtures/cargo-test"
work="$(t_mktemp -d)"

# _convert <log> <xml> <status>: the converter's summary line in ${work}/out, and its status asserted.
_convert() {
  local rc=0
  python3 "${RUST_DIR}/cargo-test-junit.py" "$1" "$2" > "${work}/out" 2>&1 || rc=$?
  t_assert_eq "$3" "${rc}" "converter status for $(basename "$1")"
}

t_case "a verbose log with a failure, a crash and doc-tests converts"
_convert "${fixtures}/verbose-pass-fail-crash.txt" "${work}/verbose.xml" 0
t_assert_grep "${work}/out" '^cargo-test-junit: 9 tests, 2 failed, 2 skipped in 3 binaries'
t_case "each binary is a suite named by its package and binary, the rustc lines name none"
t_assert_grep "${work}/verbose.xml" '<testsuite name="kataglyphis_core::kataglyphis_core" tests="4" failures="1" skipped="1" time="0.420">'
t_assert_grep "${work}/verbose.xml" '<testsuite name="kataglyphis_core::doc-tests" tests="2" failures="0" skipped="1" time="1.050">'
t_case "an ignored test keeps its reason, a failed one its captured output"
t_assert_grep "${work}/verbose.xml" '<skipped message="needs a Vulkan device" />'
t_assert_grep "${work}/verbose.xml" '^  left: 0$'
t_assert_grep "${work}/verbose.xml" "<failure message=\"thread 'config::tests::rejects_zero' panicked at crates/core/src/config.rs:88:9:\">"
t_case "a binary that died before its summary is one failure that names the signal"
t_assert_grep "${work}/verbose.xml" '<testsuite name="kataglyphis_gui::golden" tests="3" failures="1"'
t_assert_grep "${work}/verbose.xml" 'name="\(binary ended early\)"'
t_assert_grep "${work}/verbose.xml" '2 of 3 tests reported; .*SIGSEGV: invalid memory reference'

t_case "the plain form names a suite by its binary and source, without colour codes or the slow-test notice"
_convert "${fixtures}/plain-colour-slow.txt" "${work}/plain.xml" 0
t_assert_grep "${work}/plain.xml" '<testsuite name="kataglyphis_text \(unittests src/lib.rs\)" tests="1"'
t_assert_grep "${work}/plain.xml" '<testsuite name="contract \(tests/contract.rs\)" tests="1" failures="0" skipped="0" time="64.310">'
t_assert_no_grep "${work}/plain.xml" 'has been running'

printf '   Compiling kataglyphis_core v0.1.0\nerror[E0425]: cannot find value x in this scope\n' > "${work}/build-failed.txt"
t_case "a log in which no test binary ran is an error, not an empty record"
_convert "${work}/build-failed.txt" "${work}/none.xml" 1
t_assert_grep "${work}/out" 'no test binary ran'

# _cargo_test <fixture> <cargo status>: cargo_test.sh with cargo a function that prints the fixture; output in ${work}/run.
_cargo_test() {
  local dir; dir="$(mktemp -d "${work}/run.XXXXXX")"
  ( cd "${dir}" && FIXTURE="$1" STATUS="$2" HOME="${dir}" CARGO_HOME="${dir}/cargo-home" CARGO_SAFE_DIRECTORY='' bash -c '
      cargo() { case "$1" in test) cat "${FIXTURE}"; return "${STATUS}" ;; *) echo "cargo 1.0.0" ;; esac; }
      rustc() { echo "rustc 1.0.0"; }
      export -f cargo rustc
      bash "$0/cargo_test.sh"' "${RUST_DIR}" ) > "${work}/run" 2>&1
  echo "$?" >> "${work}/run"
  printf '%s' "${dir}"
}

t_case "cargo_test.sh keeps the log and writes its JUnit, and a green run stays green"
d="$(_cargo_test "${fixtures}/plain-colour-slow.txt" 0)"
t_assert_eq "0" "$(tail -n 1 "${work}/run")" "$(cat "${work}/run")"
t_assert_grep "${d}/logs/test-results/cargo-test.txt" 'test result: ok'
t_assert_grep "${d}/logs/test-results/cargo-test.xml" '<testsuite name="contract \(tests/contract.rs\)"'

t_case "a failing cargo test is the step's status, and its JUnit is written before it ends the step"
d="$(_cargo_test "${fixtures}/verbose-pass-fail-crash.txt" 101)"
t_assert_eq "101" "$(tail -n 1 "${work}/run")" "the record must not hide the failure"
t_assert_grep "${d}/logs/test-results/cargo-test.xml" 'failures="2"'

t_case "a green cargo with no test binary in its log fails: a record of nothing is no pass"
printf 'Finished dev profile\n' > "${work}/empty.txt"
d="$(_cargo_test "${work}/empty.txt" 0)"
t_assert_eq "1" "$(tail -n 1 "${work}/run")"

t_summary
