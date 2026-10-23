#!/usr/bin/env bash
# Exercises launcher setup with stubbed Git and SDK scripts; no global Git configuration is written.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../lib/project-env.sh"
w="$(mktemp -d)"
trap 'rm -rf "${w}"' EXIT
git() { printf '<%s>\n' "$@" >> "${w}/git"; return 19; }

t_case "Git directory opt-out is silent; spaces survive and configuration failure is advisory"
t_assert_ok project_env_allow_git_directory ''
t_assert_ok test ! -e "${w}/git"
t_assert_ok project_env_allow_git_directory '/workspace with spaces'
t_assert_eq '<config>
<--global>
<--add>
<safe.directory>
</workspace with spaces>' "$(cat "${w}/git")"

printf 'PROJECT_SDK=loaded\n' > "${w}/setup-env.sh"
export VULKAN_SETUP_SCRIPT="${w}/setup-env.sh"
t_case "explicit SDK setup is sourced in the caller and an absent file is optional"
t_assert_ok project_env_source_vulkan
t_assert_eq loaded "${PROJECT_SDK:-}"
export VULKAN_SETUP_SCRIPT="${w}/missing"
t_assert_ok project_env_source_vulkan

t_case "the caller hook wins over an explicit script and its failure remains visible"
source_vulkan_env() { PROJECT_SDK=hook; return 23; }
export VULKAN_SETUP_SCRIPT="${w}/setup-env.sh"
t_assert_fails project_env_source_vulkan
t_assert_eq hook "${PROJECT_SDK}"
unset -f source_vulkan_env

prepare_launcher() (
  local library="$1" fn="$2" safe_setting="$3"
  case "${library}" in
    cmake-build.sh) source "${TESTS_DIR}/../lib/cmake-build.sh" ;;
    ctest-run.sh) source "${TESTS_DIR}/../lib/ctest-run.sh" ;;
  esac
  export CARGO_HOME="${w}/cargo" TMPDIR="${w}"
  unset SCCACHE_DIR CCACHE_DIR CCACHE_SECONDARY_STORAGE
  export CMAKE_BUILD_SAFE_DIRECTORY="${safe_setting}"
  export CTEST_RUN_SAFE_DIRECTORY="${safe_setting}"
  PROJECT_SDK=''
  "$fn" >/dev/null
  printf '%s\n' "${PROJECT_SDK}"
)
t_case "both launchers invoke shared setup with their own Git directory and the explicit SDK"
for spec in 'cmake-build.sh cmake_build_prepare_env' 'ctest-run.sh ctest_run_prepare_env'; do
  read -r library fn <<< "${spec}"
  : > "${w}/git"
  t_assert_eq loaded "$(prepare_launcher "${library}" "${fn}" '/chosen workspace')"
  t_assert_contains "$(cat "${w}/git")" '</chosen workspace>'
  : > "${w}/git"
  t_assert_eq loaded "$(prepare_launcher "${library}" "${fn}" '')"
  t_assert_eq '' "$(cat "${w}/git")"
done
t_summary
