#!/usr/bin/env bash
# lib/cmake-build.sh's cmake_build_main is consumer API with no caller here; these cases pin its argv, status and output.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/lib-contract-fixture.sh
source "${TESTS_DIR}/lib-contract-fixture.sh"
source "${TESTS_DIR}/test-workspace-fixture.sh"
declare _work
t_fixture_workspace_init _work || exit 1
lc_init "${_work}" || exit 1
LIB="${TESTS_DIR}/../lib/cmake-build.sh"
LOG="${_work}/argv.log"
declare out rc
lc_stub git
lc_stub cmake "case \"\$1\" in --build) exit $(lc_status build) ;; esac"
# A writable CARGO_HOME and no linker or cache override keep prepare_env quiet, as a configured image is.
ENV="export CARGO_HOME=$(printf '%q' "${_work}/cargo"); unset KATAGLYPHIS_LINKER SCCACHE_DIR CCACHE_DIR CCACHE_SECONDARY_STORAGE PRESET BUILD_DIR PARALLEL_JOBS"

t_case "cmake_build_main configures the preset into the build dir with each extra -D, then builds"
lc_call out rc "${LIB}" "${ENV}; cmake_build_main --preset rel --build-dir out --configure-arg -DA=1 --configure-arg '-DB=x y' --build-config Release --build-target app --parallel 3"
t_assert_eq "0" "${rc}"
t_assert_eq "git config --global --add safe.directory /workspace
cmake -B out --preset rel -DA=1 -DB=x y
cmake --build out --config Release --target app --parallel 3" "$(lc_argv)"
t_assert_contains "${out}" "Configuring CMake with preset: rel (+ -DA=1 -DB=x y)"
t_assert_contains "${out}" "Using specified parallel jobs: 3"
t_assert_contains "${out}" "Executing: cmake --build out --config Release --target app --parallel 3"

t_case "a configure step without a preset fails before cmake runs"
lc_reset
lc_expect 1 "Missing --preset for configure step." "${LIB}" "${ENV}; cmake_build_main"
t_assert_eq "0" "$(lc_argv | grep -c -e '^cmake' || true)"

t_case "--skip-configure builds the tree as configured; the project's get_build_jobs sizes it"
lc_reset
lc_call out rc "${LIB}" "${ENV}; get_build_jobs() { echo \"jobs-for \$1\" >> $(printf '%q' "${LOG}"); echo 7; }; CMAKE_BUILD_SAFE_DIRECTORY= cmake_build_main --skip-configure --mb-per-job 2500"
t_assert_eq "0" "${rc}"
t_assert_eq "jobs-for 2500
cmake --build build --parallel 7" "$(lc_argv)"
t_assert_contains "${out}" "Auto-detected parallel jobs: 7 (memory-aware)"

t_case "--clean-build-dir true empties the build dir before configuring"
mkdir -p "${_work}/stale"
: > "${_work}/stale/CMakeCache.txt"
lc_call out rc "${LIB}" "${ENV}; cmake_build_main --preset rel --build-dir stale --clean-build-dir true --parallel 1"
t_assert_eq "0" "${rc}"
t_assert_contains "${out}" "Cleaning build directory: stale"
t_assert_fails test -e "${_work}/stale/CMakeCache.txt"

t_case "a failing pre-build hook is fatal unless --allow-prebuild-failure downgrades it"
lc_reset
lc_expect 1 "Pre-build step (shaders) failed (pass --allow-prebuild-failure to downgrade this to a warning)" \
  "${LIB}" "${ENV}; cmake_build_prebuild_hook() { return 1; }; CMAKE_BUILD_PREBUILD_LABEL=shaders cmake_build_main --preset rel --parallel 1"
t_assert_eq "0" "$(lc_argv | grep -c -e '^cmake --build' || true)" "nothing builds without the generated inputs"
lc_reset
lc_call out rc "${LIB}" "${ENV}; cmake_build_prebuild_hook() { return 1; }; cmake_build_main --preset rel --parallel 1 --allow-prebuild-failure"
t_assert_eq "0" "${rc}"
t_assert_contains "${out}" "Pre-build step failed; continuing because --allow-prebuild-failure was given"
t_assert_contains "$(lc_argv)" "cmake --build build --parallel 1"

t_case "the build's status is the function's, and a failed environment step stops it first"
lc_fail build 4
lc_call out rc "${LIB}" "${ENV}; cmake_build_main --preset rel --parallel 1"
t_assert_eq "4" "${rc}"
lc_pass build
lc_reset
lc_expect 2 "KATAGLYPHIS_LINKER must be default, lld or mold, not 'gold'" "${LIB}" "${ENV}; KATAGLYPHIS_LINKER=gold cmake_build_main --preset rel --parallel 1"
t_assert_eq "0" "$(lc_argv | grep -c -e '^cmake' || true)"

t_case "an unknown flag and the retired sanitizer flag fail with their reason"
lc_expect 1 "Unknown argument: --frobnicate" "${LIB}" "${ENV}; cmake_build_main --frobnicate"
lc_call out rc "${LIB}" "${ENV}; cmake_build_main --use-thread-sanitizer"
t_assert_contains "${out}" "--use-thread-sanitizer does nothing (legacy plumbing)"

t_summary
