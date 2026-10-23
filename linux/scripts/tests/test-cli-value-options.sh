#!/usr/bin/env bash
# Real parsers run in bounded child shells; no build, ctest invocation or application launch occurs.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cat > "${WORK}/parse.sh" <<'WORKER'
#!/usr/bin/env bash
set -u
lib="$1" mode="$2"; shift 2
source "${lib}/${mode}.sh"
case "${mode}" in
  app-runner)
    APP_RUNNER_DEFAULT_EXE_NAME=default
    APP_RUNNER_DEFAULT_BUILD_DIR=default-build
    APP_RUNNER_DEFAULT_BUILD_TYPE=Debug
    app_runner_parse_args "$@"
    printf 'ARGS'; printf ' <%s>' "${APP_ARGS[@]}"; printf '\n'
    ;;
  ctest-run)
    ctest_run_parse_args "$@"
    printf 'ARGS'; printf ' <%s>' "${CTEST_RUN_PASSTHROUGH[@]}"; printf '\n'
    ;;
  cmake-build) cmake_build_parse_args "$@" ;;
esac
for key in EXE_NAME BUILD_DIR BUILD_TYPE VULKAN_VERSION VULKAN_SETUP_SCRIPT VULKAN_SDK CTEST_EXCLUDE PRESET CMAKE_BUILD_CONFIG CMAKE_BUILD_TARGET CARGO_CACHE_DIR PARALLEL_JOBS MB_PER_JOB; do
  printf '%s=%s\n' "${key}" "${!key-}"
done
WORKER
_parse() { timeout 3 bash "${WORK}/parse.sh" "${TESTS_DIR}/../lib" "$@"; }
t_case "app values keep spaces, repeated-option priority and argument passthrough"
out="$(_parse app-runner --exe-name custom --build-dir old --build-dir 'new build' --build-type Release -- --raw 'a b')"
t_assert_contains "${out}" 'EXE_NAME=custom'
t_assert_contains "${out}" 'BUILD_DIR=new build'
t_assert_contains "${out}" 'BUILD_TYPE=Release'
t_assert_contains "${out}" 'ARGS <--raw> <a b>'
t_case "ctest values retain Vulkan forwarding and positional passthrough"
out="$(_parse ctest-run --vulkan-version v --vulkan-setup-script '/setup script' --vulkan-sdk '/SDK root' --build-dir tree --build-type Rel --ctest-exclude slow case --later)"
for expected in 'VULKAN_VERSION=v' 'VULKAN_SETUP_SCRIPT=/setup script' 'VULKAN_SDK=/SDK root' 'BUILD_DIR=tree' 'BUILD_TYPE=Rel' 'CTEST_EXCLUDE=slow' 'ARGS <case> <--later>'; do
  t_assert_contains "${out}" "${expected}"
done
t_case "cmake values reach their distinct local or global outputs"
out="$(_parse cmake-build --preset preset --build-dir tree --clean-build-dir true --build-config Release --build-target install --cargo-cache-dir '/cargo root' --parallel 2 --mb-per-job 512 --vulkan-version version --vulkan-setup-script '/setup file' --vulkan-sdk '/vulkan root')"
for expected in 'PRESET=preset' 'BUILD_DIR=tree' 'CMAKE_BUILD_CONFIG=Release' 'CMAKE_BUILD_TARGET=install' 'CARGO_CACHE_DIR=/cargo root' 'PARALLEL_JOBS=2' 'MB_PER_JOB=512' 'VULKAN_VERSION=version' 'VULKAN_SETUP_SCRIPT=/setup file' 'VULKAN_SDK=/vulkan root'; do
  t_assert_contains "${out}" "${expected}"
done
t_case "an explicitly empty value remains distinct from a missing argument"
t_assert_eq 0 "$(t_rc _parse app-runner --build-dir '')"
t_assert_contains "$(_parse app-runner --build-dir '')" $'BUILD_DIR=\n'
t_assert_eq 0 "$(t_rc _parse ctest-run --build-dir '')"
t_assert_eq 0 "$(t_rc _parse cmake-build --preset '')"
while read -r mode flags; do
  for flag in ${flags}; do
    t_case "${mode} ${flag}: a missing value exits rather than looping"
    status="$(t_rc _parse "${mode}" "${flag}")"
    t_assert_eq 1 "${status}"
    [ "${status}" != 124 ] || break 2
    t_assert_contains "$(t_out _parse "${mode}" "${flag}")" "${flag} expects a value"
  done
done <<'FLAGS'
app-runner --exe-name --build-dir --build-type
ctest-run --vulkan-version --vulkan-setup-script --vulkan-sdk --build-dir --build-type --ctest-exclude
cmake-build --preset --build-dir --clean-build-dir --build-config --build-target --cargo-cache-dir --parallel --mb-per-job --vulkan-version --vulkan-setup-script --vulkan-sdk
FLAGS
t_summary
