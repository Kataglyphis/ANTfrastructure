#!/usr/bin/env bash
# Configure the full pinned rocmlirTriton source; no vendor libraries are built, installed or accepted here.
set -euo pipefail
# shellcheck source=linux/scripts/03-media/build/migraphx/cli-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/cli-common.sh" 'NEW_WORK ROCMLIR_ARCHIVE ROCM_CMAKE_ARCHIVE ROCM_ROOT' 4 "$@"
archive="$2" rocm_cmake_archive="$3" rocm="$4"
source "${SCRIPT_DIR}/entry-common.sh"
source "${SCRIPT_DIR}/source-rocmlir.sh"
clang_root='' gcc_root=''
migraphx_prepare_native_work "${work}" work clang_root gcc_root
migraphx_prepare_source_tree "${archive}" "${MIGRAPHX_ROCMLIR_SOURCE_SHA256}" "${work}/source"
migraphx_rocmlir_source_contract "${work}/source"
migraphx_stage_rocmlir_notices "${work}/source" "${work}/source-notices" "${SCRIPT_DIR}/rocmlir-source-notices.sha256"
migraphx_prepare_rocm_cmake "${work}" "${rocm_cmake_archive}"
setup_host_python_environment
declare -a cmake_args=()
migraphx_rocmlir_cmake_plan cmake_args "${work}" "${rocm}" "${clang_root}" "${gcc_root}" "${HOST_PYTHON_BIN}"
cmake "${cmake_args[@]}"
cmake_assert_compiler_cache_pin "${work}/build" "${CMAKE_COMPILER_CACHE_PIN:-}"
cmake_assert_configured_entries "${work}/build" bool \
  BUILD_FAT_LIBROCKCOMPILER=ON BUILD_SHARED_LIBS=OFF CMAKE_POSITION_INDEPENDENT_CODE=ON \
  LLVM_INCLUDE_TESTS=OFF MLIR_INCLUDE_TESTS=OFF MLIR_ENABLE_ROCM_RUNNER=OFF \
  TRITON_OFFLINE_BUILD=ON FETCHCONTENT_FULLY_DISCONNECTED=ON FETCHCONTENT_UPDATES_DISCONNECTED=ON
cmake_assert_configured_entries "${work}/build" first \
  "CMAKE_C_COMPILER=${clang_root}/bin/clang" "CMAKE_CXX_COMPILER=${clang_root}/bin/clang++" \
  "CMAKE_INSTALL_PREFIX=${work}/host-deps" "LLVM_TARGETS_TO_BUILD=X86;AMDGPU"
printf 'ROCMLIR SOURCE CONFIGURED: full pinned source; library build, binary notice review and acceptance remain required\n'
