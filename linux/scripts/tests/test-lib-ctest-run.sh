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
ctest -C Debug ${FLAGS}
cwd build" "$(lc_argv)"
t_assert_contains "${out}" "Changing to build directory: build"
t_assert_contains "${out}" "Executing: ctest -C Debug ${FLAGS}"

t_case "flags pick the tree, configuration and exclusion; everything after -- is passed on"
lc_reset
lc_call out rc "${LIB}" 'ctest_run_main --build-dir tree --build-type Release --ctest-exclude slow -- -R unit -j4'
t_assert_eq "${SAFE}
ctest -C Release ${FLAGS} -E slow -R unit -j4
cwd tree" "$(lc_argv)"
t_assert_contains "${out}" "Excluding tests matching: slow"

t_case "the environment and caller defaults sit below the flags"
lc_reset
lc_call out rc "${LIB}" 'CTEST_RUN_DEFAULT_ARGS=(--no-tests=error); BUILD_TYPE=RelWithDebInfo CTEST_RUN_SAFE_DIRECTORY= ctest_run_main'
t_assert_eq "ctest -C RelWithDebInfo --no-tests=error
cwd build" "$(lc_argv)" "CTEST_RUN_DEFAULT_ARGS replaces the built-ins; an empty safe directory skips git"

t_case "ctest's status is the function's, and a missing tree or unknown flag fails first"
lc_fail ctest 8
lc_call out rc "${LIB}" 'ctest_run_main'
t_assert_eq "8" "${rc}"
lc_pass ctest
lc_reset
lc_expect 1 "Build directory not found: absent. Configure/build it first." "${LIB}" 'ctest_run_main --build-dir absent'
t_assert_eq "0" "$(lc_argv | grep -c -e '^ctest' || true)" "no suite runs in the wrong directory"
lc_expect 1 "Unknown argument: --frobnicate" "${LIB}" 'ctest_run_main --frobnicate'

t_case "--help prints the usage with the caller's defaults and exits 0"
lc_call out rc "${LIB}" 'CTEST_RUN_DEFAULT_BUILD_DIR=out ctest_run_main --help'
t_assert_eq "0" "${rc}"
t_assert_contains "${out}" "--build-dir DIR          build tree to run ctest in (default: out)"

t_summary
