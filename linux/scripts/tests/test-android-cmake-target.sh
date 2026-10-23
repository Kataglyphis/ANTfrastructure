#!/usr/bin/env bash
# Argument fixtures cover target selection and quoting, not NDK execution or project configuration.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PREAMBLE="${TESTS_DIR}/../03-media/android-build-preamble.sh"
eval "$(t_fn_src "${PREAMBLE}" android_cmake_target_args)"
export ANDROID_NDK_HOME='/fixture/NDK with spaces'
export ANDROID_API_LEVEL=35
args=(stale)
for ANDROID_ABI in arm64-v8a x86_64 riscv64; do
  t_case "target argument array preserves ${ANDROID_ABI} and replaces previous entries"
  android_cmake_target_args args
  t_assert_eq 3 "${#args[@]}"
  t_assert_eq '-DCMAKE_TOOLCHAIN_FILE=/fixture/NDK with spaces/build/cmake/android.toolchain.cmake' "${args[0]}"
  t_assert_eq "-DANDROID_ABI=${ANDROID_ABI}" "${args[1]}"
  t_assert_eq '-DANDROID_PLATFORM=android-35' "${args[2]}"
done

t_case "all Android consumers initialize and expand the shared argument array"
for project in iree litert opencv; do
  script="${TESTS_DIR}/../03-media/build/${project}/android/build-android.sh"
  t_assert_grep "${script}" '^android_cmake_target_args ANDROID_CMAKE_TARGET_ARGS$'
  t_assert_grep "${script}" '"\$\{ANDROID_CMAKE_TARGET_ARGS\[@\]\}"'
  t_assert_no_grep "${script}" 'DANDROID_(ABI|PLATFORM)='
done
t_summary
