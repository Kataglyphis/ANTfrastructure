#!/usr/bin/env bash
# lib/coverage.sh's llvm half is consumer API with no caller here; these cases pin its argv, status and output.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/lib-contract-fixture.sh
source "${TESTS_DIR}/lib-contract-fixture.sh"
source "${TESTS_DIR}/test-workspace-fixture.sh"
declare _work
t_fixture_workspace_init _work || exit 1
lc_init "${_work}" || exit 1
LIB="${TESTS_DIR}/../lib/coverage.sh"
declare out rc

# A suite that writes the profile it is told to and reports what it ran with.
printf '#!/usr/bin/env bash\nprintf "suite %%s|%%s|%%s\\n" "$*" "${LLVM_PROFILE_FILE}" "${ASAN_OPTIONS-}" >> %q\n[ -e %q ] || : > "${LLVM_PROFILE_FILE}"\nexit %s\n' \
  "${_work}/argv.log" "${_work}/rc/no-profile" "$(lc_status suite)" > "${_work}/suite"
chmod +x "${_work}/suite"

t_case "coverage_llvm_generate_profile runs the suite with the profile path and detect_leaks off"
lc_call out rc "${LIB}" 'coverage_llvm_generate_profile ./suite prof/run.profraw --gtest_brief=1'
t_assert_eq "0" "${rc}"
t_assert_eq "suite --gtest_brief=1|prof/run.profraw|detect_leaks=0" "$(lc_argv)" "argv, LLVM_PROFILE_FILE and the default run env"
t_assert_contains "${out}" "Running ./suite to generate coverage data"
t_assert_ok test -f "${_work}/prof/run.profraw"

t_case "COVERAGE_LLVM_RUN_ENV replaces the default run env"
lc_reset
lc_call out rc "${LIB}" 'COVERAGE_LLVM_RUN_ENV=(ASAN_OPTIONS=halt_on_error=1); coverage_llvm_generate_profile ./suite p.profraw'
t_assert_eq "suite |p.profraw|halt_on_error=1" "$(lc_argv)"

t_case "a missing suite and a suite that wrote no profile both fail with their reason"
lc_expect 1 "Test executable not found at ./absent. Build the project first." "${LIB}" 'coverage_llvm_generate_profile ./absent p.profraw'
rm -f "${_work}/p.profraw"
lc_fail no-profile 1
lc_expect 1 "Profile data still not found at p.profraw after running the suite." "${LIB}" 'coverage_llvm_generate_profile ./suite p.profraw'
lc_pass no-profile

t_case "a failing suite that wrote its profile still returns 0 (BACKLOG CON208)"
lc_fail suite 3
lc_call out rc "${LIB}" 'coverage_llvm_generate_profile ./suite p.profraw'
t_assert_eq "0" "${rc}" "today the profile's presence is the verdict, not the suite's status"
lc_pass suite

t_case "coverage_llvm_report merges, reports and skips empty ignore patterns"
lc_stub llvm-profdata
lc_stub llvm-cov 'case "$1" in export) printf "{\"data\":[]}\n" ;; report) printf "TOTAL 90%%\n" ;; esac'
lc_reset
lc_call out rc "${LIB}" 'COVERAGE_LLVM_IGNORE_REGEX=("third_party/" "" "test/"); coverage_llvm_report ./suite p.profraw p.profdata'
t_assert_eq "0" "${rc}"
t_assert_eq "llvm-profdata merge -sparse p.profraw -o p.profdata
llvm-cov report ./suite -instr-profile=p.profdata -ignore-filename-regex=third_party/ -ignore-filename-regex=test/" "$(lc_argv)"
t_assert_contains "${out}" "TOTAL 90%"

t_case "a JSON path exports, and COVERAGE_LLVM_HTML_DIR writes the HTML report"
lc_reset
lc_call out rc "${LIB}" 'COVERAGE_LLVM_HTML_DIR=html coverage_llvm_report ./suite p.profraw p.profdata out.json'
t_assert_eq "0" "${rc}"
t_assert_eq '{"data":[]}' "$(cat "${_work}/out.json")" "export goes to the JSON path"
t_assert_eq "llvm-profdata merge -sparse p.profraw -o p.profdata
llvm-cov report ./suite -instr-profile=p.profdata
llvm-cov export ./suite -format=text -instr-profile=p.profdata
llvm-cov show ./suite -instr-profile=p.profdata -format=html -output-dir html" "$(lc_argv)"
t_assert_ok test -d "${_work}/html"
t_assert_contains "${out}" "Writing browsable HTML coverage report to html"

t_case "coverage_llvm_report needs both llvm tools"
rm -f "${_work}/bin/llvm-cov"
lc_call_bare out rc "${LIB}" 'coverage_llvm_report ./suite p.profraw p.profdata'
t_assert_eq "1" "${rc}"
t_assert_contains "${out}" "Required tools not found: llvm-cov"

t_summary
