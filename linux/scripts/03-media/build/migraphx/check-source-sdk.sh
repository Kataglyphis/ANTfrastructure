#!/usr/bin/env bash
# Fail on unavailable selected SDK packages before a producer pays for parser dependencies; metadata is not inference.
set -euo pipefail
# shellcheck source=linux/scripts/03-media/build/migraphx/native-check-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/native-check-common.sh" "$@"
setup_host_python_environment
pybind_status=0
"${HOST_PYTHON_BIN}" -m pybind11 --cmakedir > "${work}/pybind11-dir.txt" 2> "${work}/pybind11-stderr.txt" || pybind_status=$?
printf '%s\n' "${pybind_status}" > "${work}/pybind11-status.txt"
prefix_path="${rocm};${rocm}/core;${rocm}/core/lib/rocm_sysdeps;${rocm}/extras-${ROCM_VERSION%%.*}/lib/migraphx"
if [[ -n "${MIGRAPHX_DEPS_PREFIX:-}" ]]; then prefix_path="${MIGRAPHX_DEPS_PREFIX};${prefix_path}"; fi
cmake_args=(
  "-DCMAKE_PREFIX_PATH=${prefix_path}"
)
if [[ "${pybind_status}" -eq 0 ]]; then
  pybind_dir="$(cat "${work}/pybind11-dir.txt")"
  cmake_args+=("-Dpybind11_DIR=${pybind_dir}")
fi
migraphx_prepare_cmake_plan cmake_args "${clang_root}" "${gcc_root}" "${work}/cmake-argv.nul" "${SCRIPT_DIR}/sdk-closure" "${work}/build"
status=0
cmake "${cmake_args[@]}" > "${work}/sdk-cmake.log" 2>&1 || status=$?
printf '%s\n' "${status}" > "${work}/cmake-status.txt"
if [[ "${status}" -ne 0 ]]; then cat "${work}/sdk-cmake.log" >&2; exit "${status}"; fi
cmake_assert_compiler_cache_pin "${work}/build" "${CMAKE_COMPILER_CACHE_PIN:-}"
cmake_assert_configured_entries "${work}/build" first \
  "CMAKE_C_COMPILER=${clang_root}/bin/clang" "CMAKE_CXX_COMPILER=${clang_root}/bin/clang++"
printf 'SDK DEVELOPMENT PACKAGES RESOLVED: backend compilation and acceptance remain required\n'
