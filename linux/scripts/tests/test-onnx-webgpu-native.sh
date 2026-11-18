#!/usr/bin/env bash
# A real dlopen/C probe runs against a fake test ABI; this does not prove real ORT ABI, target images or GPU inference.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_skip_unless 'Linux dynamic-loader fixtures' test "$(uname -s)" = Linux
for tool in cc cmake; do t_skip_unless "${tool}" command -v "${tool}"; done
t_private_tmpdir
work="$(t_mktemp -d)"
common="${TESTS_DIR}/../03-media/build/onnxruntime/build/lib/common.sh"
project="${1:-${common%/*}/webgpu-factory-probe}"
mkdir -p "${work}/parent with spaces" "${work}/headers with spaces"
cp "${TESTS_DIR}/fixtures/webgpu-native/onnxruntime_c_api.h" "${work}/headers with spaces/"
printf 'CMAKE_C_COMPILER:FILEPATH=%s\nCMAKE_C_FLAGS:STRING=-DWEBGPU_COMPILER_FIXTURE=37 -DWEBGPU_SECOND_FLAG=41\nCMAKE_BUILD_TYPE:STRING=Release\n' "$(command -v cc)" > "${work}/parent with spaces/CMakeCache.txt"
parent_before="$(sha256sum "${work}/parent with spaces/CMakeCache.txt")"
cmake -S "${project}" -B "${work}/build" "-DORT_CONFIG_DIR=${work}/parent with spaces" \
  "-DORT_INCLUDE_DIR=${work}/headers with spaces" -DCMAKE_C_COMPILER=/bin/false > "${work}/configure.log" 2>&1 || { cat "${work}/configure.log"; exit 1; }
cmake --build "${work}/build" > "${work}/build.log" 2>&1 || { cat "${work}/build.log"; exit 1; }
t_assert_eq "${parent_before}" "$(sha256sum "${work}/parent with spaces/CMakeCache.txt")" 'probe configuration never rewrites the native build cache'
mkdir -p "${work}/no compiler"
printf 'CMAKE_C_FLAGS:STRING=-DWEBGPU_COMPILER_FIXTURE=37 -DWEBGPU_SECOND_FLAG=41\n' > "${work}/no compiler/CMakeCache.txt"
t_assert_fails cmake -S "${project}" -B "${work}/missing compiler build" "-DORT_CONFIG_DIR=${work}/no compiler" \
  "-DORT_INCLUDE_DIR=${work}/headers with spaces" "-DCMAKE_C_COMPILER=$(command -v cc)"
t_assert_fails cmake -S "${project}" -B "${work}/missing header build" "-DORT_CONFIG_DIR=${work}/parent with spaces" \
  "-DORT_INCLUDE_DIR=${work}/missing headers"
cc -shared -fPIC -DWEBGPU_COMPILER_FIXTURE=37 -DWEBGPU_SECOND_FLAG=41 \
  -o "${work}/core.so" "${TESTS_DIR}/fixtures/webgpu-native/core.c" || exit $?
cc -shared -fPIC -o "${work}/close-failure.so" "${TESTS_DIR}/fixtures/webgpu-native/close-failure.c" || exit $?
output='' status=0
t_capture_command output status python3 "${TESTS_DIR}/ort_webgpu_native_tests.py" \
  "${common%/*}/ort-webgpu-build-proof.py" "${work}/core.so" "${common}" "${work}/build/ort-webgpu-factory-probe" \
  "${2:-${TESTS_DIR}/../03-media/runtime/ort_webgpu_runtime.py}" "${work}/close-failure.so"
printf '%s\n' "${output}"
t_assert_eq 0 "${status}" 'native C API verdicts and checked runtime invocation must pass'
t_summary
