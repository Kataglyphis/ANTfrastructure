#!/usr/bin/env bash
# lib/ctest-run.sh's ctest_run_main is consumer API with no caller here; these cases pin its argv, status and output.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/lib-contract-fixture.sh
source "${TESTS_DIR}/lib-contract-fixture.sh"
source "${TESTS_DIR}/test-workspace-fixture.sh"
declare _work
t_fixture_workspace_init _work || exit 1
lc_init "${_work}" || exit 1
LIB="${TESTS_DIR}/../lib/ctest-run.sh"
declare out rc
mkdir -p "${_work}/build" "${_work}/tree"
lc_stub git
lc_stub ctest "printf 'cwd %s\n' \"\${PWD##*/}\" >> $(printf '%q' "${_work}/argv.log"); exit $(lc_status ctest)"
SAFE="git config --global --add safe.directory /workspace"
FLAGS="--verbose --extra-verbose --debug -T test --output-on-failure"

t_case "ctest_run_main marks the workspace safe, enters the build tree and runs ctest with the built-in flags"
lc_call out rc "${LIB}" 'ctest_run_main'
t_assert_eq "0" "${rc}"
t_assert_eq "${SAFE}
ctest -C Debug ${FLAGS} --timeout 1500
cwd build" "$(lc_argv)"
t_assert_contains "${out}" "Changing to build directory: build"
t_assert_contains "${out}" "Executing: ctest -C Debug ${FLAGS} --timeout 1500"

t_case "flags pick the tree, configuration and exclusion; everything after -- is passed on"
lc_reset
lc_call out rc "${LIB}" 'ctest_run_main --build-dir tree --build-type Release --ctest-exclude slow -- -R unit -j4'
t_assert_eq "${SAFE}
ctest -C Release ${FLAGS} -E slow --timeout 1500 -R unit -j4
cwd tree" "$(lc_argv)"
t_assert_contains "${out}" "Excluding tests matching: slow"

t_case "the environment and caller defaults sit below the flags"
lc_reset
lc_call out rc "${LIB}" 'CTEST_RUN_DEFAULT_ARGS=(--no-tests=error); BUILD_TYPE=RelWithDebInfo CTEST_RUN_SAFE_DIRECTORY= ctest_run_main'
t_assert_eq "ctest -C RelWithDebInfo --no-tests=error --timeout 1500
cwd build" "$(lc_argv)" "CTEST_RUN_DEFAULT_ARGS replaces the built-ins, not the per-test limit; an empty safe directory skips git"

t_case "a hung test ends named: the per-test limit has a default, and a caller's own value replaces it"
lc_reset
lc_call out rc "${LIB}" 'ctest_run_main --timeout 90'
t_assert_eq "ctest -C Debug ${FLAGS} --timeout 90" "$(lc_argv | grep -e '^ctest')"
lc_reset
lc_call out rc "${LIB}" 'CTEST_RUN_DEFAULT_TIMEOUT=600 ctest_run_main -- --timeout 30'
t_assert_eq "ctest -C Debug ${FLAGS} --timeout 30" "$(lc_argv | grep -e '^ctest')" "one --timeout, the caller's"
lc_reset
lc_call out rc "${LIB}" 'ctest_run_main --timeout 0'
t_assert_eq "ctest -C Debug ${FLAGS}" "$(lc_argv | grep -e '^ctest')" "0 sets none"
lc_expect 1 "--timeout needs whole seconds, got: soon" "${LIB}" 'ctest_run_main --timeout soon'

t_case "ctest's status is the function's, and a missing tree or unknown flag fails first"
lc_fail ctest 8
lc_call out rc "${LIB}" 'ctest_run_main'
t_assert_eq "8" "${rc}"
lc_pass ctest
lc_reset
lc_expect 1 "Build directory not found: absent. Configure/build it first." "${LIB}" 'ctest_run_main --build-dir absent'
t_assert_eq "0" "$(lc_argv | grep -c -e '^ctest' || true)" "no suite runs in the wrong directory"
lc_expect 1 "Unknown argument: --frobnicate" "${LIB}" 'ctest_run_main --frobnicate'

# The fixture is ctest 4.4.3's own report: ok and Gpu.Ran ran, Gpu.Skipped and the rc77 test skipped, Gpu.Disabled disabled.
JUNIT="${TESTS_DIR}/fixtures/ctest-run/junit.xml"
REPORT="${_work}/report.xml"
lc_stub ctest "printf 'cwd %s\n' \"\${PWD##*/}\" >> $(printf '%q' "${_work}/argv.log"); p=; for a in \"\$@\"; do if [ \"\${p}\" = --output-junit ] && [ -f $(printf '%q' "${REPORT}") ]; then cp $(printf '%q' "${REPORT}") \"\${a}\"; fi; p=\"\${a}\"; done; exit $(lc_status ctest)"
cp "${JUNIT}" "${REPORT}"
_tmp_left() { find "${_work}/tmp" -mindepth 1 | wc -l | tr -d ' '; }

t_case "--fail-on-skipped fails a run whose matching test was skipped, naming it, and never counts a Disabled one"
lc_reset
lc_call out rc "${LIB}" 'ctest_run_main --fail-on-skipped "^Gpu\."'
t_assert_eq "1" "${rc}"
t_assert_contains "${out}" "Skipped, which --fail-on-skipped forbids: Gpu.Skipped (SKIP_REGULAR_EXPRESSION_MATCHED)"
t_assert_contains "${out}" "--fail-on-skipped: 1 of 3 tests matching ^Gpu\. were skipped"
t_assert_eq "0" "$(grep -c -e 'forbids: Gpu.Disabled' <<<"${out}")" "Disabled is ctest's own exemption"
t_assert_contains "$(lc_argv)" "--output-junit ${_work}/tmp/ctest-run-junit."
t_assert_eq "0" "$(_tmp_left)" "the temporary report is removed"

t_case "under a caller's set -e, as consumer wrappers run, a pattern that misses the empty name still reaches the verdict"
lc_call out rc "${LIB}" 'set -e; ctest_run_main --fail-on-skipped "^Gpu\."; echo unreachable'
t_assert_eq "1" "${rc}"
t_assert_contains "${out}" "1 of 3 tests matching ^Gpu\. were skipped"
lc_call out rc "${LIB}" 'set -e; ctest_run_main --fail-on-skipped "^ok$"; echo reached'
t_assert_eq "0" "${rc}"
t_assert_contains "${out}" "reached"

t_case "a Disabled test, a test that ran and a skip the pattern does not match pass"
lc_call out rc "${LIB}" 'ctest_run_main --fail-on-skipped "Disabled|^ok$|Gpu\.Ran"'
t_assert_eq "0" "${rc}"
t_assert_contains "${out}" "--fail-on-skipped: 3 tests match Disabled|^ok$|Gpu\.Ran, none skipped (1 disabled)"

t_case "a return-code skip counts, and an escaped name is matched and printed as ctest named it"
lc_call out rc "${LIB}" 'ctest_run_main --fail-on-skipped "space & <x>"'
t_assert_eq "1" "${rc}"
t_assert_contains "${out}" "forbids: rc77 with space & <x> (SKIP_RETURN_CODE=77)"

t_case "ctest's own failure status wins over the skip verdict, and the skip is still named"
lc_fail ctest 8
lc_call out rc "${LIB}" 'ctest_run_main --fail-on-skipped Gpu'
t_assert_eq "8" "${rc}"
t_assert_contains "${out}" "forbids: Gpu.Skipped"
lc_pass ctest

t_case "a caller's --output-junit is the report read and kept, and no second one is added"
lc_reset
lc_call out rc "${LIB}" 'ctest_run_main --fail-on-skipped Gpu -- --output-junit mine.xml'
t_assert_eq "1" "${rc}"
t_assert_eq "1" "$(lc_argv | grep -o -e '--output-junit' | wc -l | tr -d ' ')"
t_assert_ok cmp "${JUNIT}" "${_work}/build/mine.xml"

t_case "no report is a failure even when ctest passed, and an old report cannot stand in for it"
rm -f "${REPORT}"
lc_expect 1 "--fail-on-skipped: ctest wrote no readable JUnit report at mine.xml" "${LIB}" 'ctest_run_main --fail-on-skipped "^ok$" -- --output-junit mine.xml'
lc_expect 1 "ctest wrote no readable JUnit report at ${_work}/tmp/ctest-run-junit." "${LIB}" 'ctest_run_main --fail-on-skipped "^ok$"'
t_assert_eq "0" "$(_tmp_left)" "the temporary report is removed after a failed read too"
cp "${JUNIT}" "${REPORT}"

t_case "a report that marks a Disabled test as skipped still exempts it"
printf '<testsuite><testcase name="Old.Disabled" status="notrun"><skipped message="Disabled"/></testcase></testsuite>\n' > "${REPORT}"
lc_call out rc "${LIB}" 'ctest_run_main --fail-on-skipped Old'
t_assert_eq "0" "${rc}"
t_assert_contains "${out}" "1 tests match Old, none skipped (1 disabled)"
cp "${JUNIT}" "${REPORT}"

t_case "the environment sets a pattern and the flag replaces it; an invalid pattern fails before ctest runs"
lc_call out rc "${LIB}" 'CTEST_FAIL_ON_SKIPPED="^Gpu\." ctest_run_main'
t_assert_eq "1" "${rc}"
lc_call out rc "${LIB}" 'CTEST_FAIL_ON_SKIPPED="^Gpu\." ctest_run_main --fail-on-skipped "^ok$"'
t_assert_eq "0" "${rc}"
lc_reset
lc_expect 1 "--fail-on-skipped needs an extended regular expression, got: (" "${LIB}" 'ctest_run_main --fail-on-skipped "("'
t_assert_eq "0" "$(lc_argv | grep -c -e '^ctest' || true)" "no suite runs with a pattern that cannot match"

t_case "real ctest: its Skipped test fails the run and its Disabled test does not"
t_needs ctest command -v ctest
mkdir -p "${_work}/real"
cat > "${_work}/real/CTestTestfile.cmake" <<'CTEST'
add_test([=[Gpu.Ran]=] "sh" "-c" "exit 0")
add_test([=[Gpu.Skipped]=] "sh" "-c" "echo '[  SKIPPED ] no device'")
set_tests_properties([=[Gpu.Skipped]=] PROPERTIES SKIP_REGULAR_EXPRESSION "\\[  SKIPPED \\]")
add_test([=[Gpu.Disabled]=] "sh" "-c" "exit 0")
set_tests_properties([=[Gpu.Disabled]=] PROPERTIES DISABLED TRUE)
CTEST
_real() { (cd "${_work}" && TMPDIR="${_work}/tmp" CTEST_RUN_SAFE_DIRECTORY='' bash -c "source $(printf '%q' "${LIB}"); ctest_run_main --build-dir real $1" 2>&1); }
out="$(_real '--fail-on-skipped "^Gpu\."')"; rc=$?
t_assert_eq "1" "${rc}"
t_assert_contains "${out}" "Skipped, which --fail-on-skipped forbids: Gpu.Skipped (SKIP_REGULAR_EXPRESSION_MATCHED)"
out="$(_real '--fail-on-skipped "Disabled|Ran"')"; rc=$?
t_assert_eq "0" "${rc}"
t_assert_contains "${out}" "2 tests match Disabled|Ran, none skipped (1 disabled)"
t_assert_eq "0" "$(_tmp_left)"

t_case "--help prints the usage with the caller's defaults and exits 0"
lc_call out rc "${LIB}" 'CTEST_RUN_DEFAULT_BUILD_DIR=out ctest_run_main --help'
t_assert_eq "0" "${rc}"
t_assert_contains "${out}" "--build-dir DIR          build tree to run ctest in (default: out)"

t_summary
