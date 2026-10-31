#!/usr/bin/env bash
# lib/app-runner.sh's app_runner_main is consumer API with no caller here; these cases pin its argv, status and output.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/lib-contract-fixture.sh
source "${TESTS_DIR}/lib-contract-fixture.sh"
source "${TESTS_DIR}/test-workspace-fixture.sh"
declare _work
t_fixture_workspace_init _work || exit 1
lc_init "${_work}" || exit 1
LIB="${TESTS_DIR}/../lib/app-runner.sh"
LOG="${_work}/argv.log"
declare out rc

# _app <path>: an executable that records its argv, working directory and loader path.
_app() {
  mkdir -p "$(dirname "${_work}/$1")"
  printf '#!/usr/bin/env bash\nprintf "app %%s|%%s|%%s\\n" "$*" "${PWD##*/}" "${LD_LIBRARY_PATH}" >> %q\nexit %s\n' "${LOG}" "$(lc_status app)" > "${_work}/$1"
  chmod +x "${_work}/$1"
}
# The caller's get_project_root decides the root, so no git or cwd guess reaches the case.
APP="app |proj|${_work}/proj/build:${_work}/proj/build/bin:"
ROOT="get_project_root() { printf '%s\n' $(printf '%q' "${_work}/proj"); }; APP_RUNNER_DEFAULT_EXE_NAME=viewer APP_RUNNER_DEFAULT_BUILD_DIR=build APP_RUNNER_DEFAULT_BUILD_TYPE=Debug; LD_LIBRARY_PATH="

t_case "app_runner_main finds the build's executable and execs it from the project root with the build on the loader path"
_app proj/build/bin/viewer
lc_call out rc "${LIB}" "${ROOT}; LD_LIBRARY_PATH=/opt/lib app_runner_main -- --scene demo"
t_assert_eq "0" "${rc}"
t_assert_eq "app --scene demo|proj|${_work}/proj/build:${_work}/proj/build/bin:/opt/lib" "$(lc_argv)"
t_assert_contains "${out}" "Starting: ${_work}/proj/build/bin/viewer"
t_assert_contains "${out}" "Working directory: ${_work}/proj"

t_case "flags choose the executable, tree and configuration; a build-type directory is searched"
lc_reset
_app proj/out/Release/demo
lc_call out rc "${LIB}" "${ROOT}; APP_RUNNER_LABEL=gpu app_runner_main --exe-name demo --build-dir out --build-type Release first"
t_assert_eq "app first|proj|${_work}/proj/out:${_work}/proj/out/bin:" "$(lc_argv)"
t_assert_contains "${out}" "Starting (gpu): ${_work}/proj/out/Release/demo"

t_case "an executable three levels down is found by name, and its status is the caller's"
lc_reset
_app proj/deep/a/b/viewer
lc_fail app 5
lc_call out rc "${LIB}" "${ROOT}; app_runner_main --build-dir $(printf '%q' "${_work}/proj/deep")"
t_assert_eq "5" "${rc}" "exec hands the app's status to the caller"
lc_pass app
t_assert_contains "$(lc_argv)" "app |proj|${_work}/proj/deep:"

t_case "a missing executable or unknown option fails with its reason"
lc_expect 1 "Executable 'viewer' not found in '${_work}/proj/nowhere'. Please build the project first." "${LIB}" "${ROOT}; app_runner_main --build-dir nowhere"
lc_expect 1 "Unknown option: --clean-and-rebuild-shaders" "${LIB}" "${ROOT}; app_runner_main --clean-and-rebuild-shaders"

t_case "the Vulkan and environment hooks run before the app, in order"
lc_reset
lc_call out rc "${LIB}" "${ROOT}; source_vulkan_env() { echo vulkan >> $(printf '%q' "${LOG}"); }; app_runner_post_vulkan_hook() { echo post >> $(printf '%q' "${LOG}"); }; app_runner_env_hook() { echo env >> $(printf '%q' "${LOG}"); }; app_runner_main"
t_assert_eq "vulkan
post
env
${APP}" "$(lc_argv)"

t_case "--clean-and-rebuild-shaders deletes .spv under the clean dir and runs the compile script"
mkdir -p "${_work}/proj/shaders"
: > "${_work}/proj/shaders/a.spv"
: > "${_work}/proj/shaders/a.slang"
printf 'echo compiled >> %q\n' "${LOG}" > "${_work}/compile.sh"
lc_reset
lc_call out rc "${LIB}" "${ROOT}; APP_RUNNER_ENABLE_SHADER_CLEAN=true APP_RUNNER_SHADER_CLEAN_DIR=shaders APP_RUNNER_SHADER_COMPILE_SCRIPT=$(printf '%q' "${_work}/compile.sh") app_runner_main --clean-and-rebuild-shaders"
t_assert_eq "0" "${rc}"
t_assert_eq "compiled
${APP}" "$(lc_argv)"
t_assert_fails test -e "${_work}/proj/shaders/a.spv"
t_assert_ok test -e "${_work}/proj/shaders/a.slang"

t_case "--help prints the usage with the caller's defaults and exits 0"
lc_call out rc "${LIB}" "${ROOT}; app_runner_main --help"
t_assert_eq "0" "${rc}"
t_assert_contains "${out}" "  --exe-name viewer"

t_summary
