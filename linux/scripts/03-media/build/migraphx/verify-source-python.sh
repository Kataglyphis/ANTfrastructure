#!/usr/bin/env bash
# This actual tiny binding checks the source Python selector, not MIGraphX compilation or GPU/image acceptance.
set -euo pipefail
# shellcheck source=linux/scripts/03-media/build/migraphx/cli-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/cli-common.sh" 'NEW_WORK PATCHED_MIGRAPHX_SOURCE' 2 "$@"
original_source="$(cd "$2" && pwd)"
source "${SCRIPT_DIR}/entry-common.sh"
clang_root='' gcc_root=''
migraphx_prepare_native_work "${work}" work clang_root gcc_root
setup_host_python_environment
pybind_dir="$("${HOST_PYTHON_BIN}" -m pybind11 --cmakedir)"
sha256sum "${original_source}/cmake/PythonModules.cmake" > "${work}/source-before.sha256"
cmake_args=(
  "-DMIGRAPHX_SOURCE=${original_source}" "-DPython_EXECUTABLE=${HOST_PYTHON_BIN}"
  "-Dpybind11_DIR=${pybind_dir}" "-DMIGRAPHX_REQUIRED_PYBIND11_VERSION=${PY_PYBIND11_VERSION}"
  "-DMIGRAPHX_REQUIRED_PYTHON_VERSION=${PYTHON_VERSION}"
)
migraphx_prepare_cmake_plan cmake_args "${clang_root}" "${gcc_root}" "${work}/cmake-argv.nul" \
  "${SCRIPT_DIR}/python-host-consumer" "${work}/build"
cmake "${cmake_args[@]}"
cmake_assert_compiler_cache_pin "${work}/build" "${CMAKE_COMPILER_CACHE_PIN:-}"
cmake_assert_configured_entries "${work}/build" first "CMAKE_CXX_COMPILER=${clang_root}/bin/clang++" \
  "MIGRAPHX_SELECTED_PYTHON_EXECUTABLE=${HOST_PYTHON_BIN}"
cmake --build "${work}/build" --parallel "${JOBS:-2}"
"${HOST_PYTHON_BIN}" "${SCRIPT_DIR}/run-python-probe.py" --build "${work}/build" \
  --version "${PYTHON_VERSION}" > "${work}/python-module-proof.json"
sha256sum "${original_source}/cmake/PythonModules.cmake" > "${work}/source-after.sha256"
cmp -- "${work}/source-before.sha256" "${work}/source-after.sha256"
printf 'MIGRAPHX PYTHON SELECTOR PASSED: exact paired headers/config and actual tiny module; backend/GPU acceptance remains required\n'
