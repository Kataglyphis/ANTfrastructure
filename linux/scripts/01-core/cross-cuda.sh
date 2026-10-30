#!/usr/bin/env bash
# The CUDA cross target a gpu stage installed (install-cuda-stack.sh); media's CUDA consumers opt in with `source_module cross-cuda.sh`.
[ -n "${_CUDA_CROSS_SH_LOADED:-}" ] && return 0
_CUDA_CROSS_SH_LOADED=1

cuda_cross_env_file() { printf '%s/cross-target.env' "${CUDA_HOME:-/usr/local/cuda}"; }

# 0 on a cross build whose base image carries a CUDA cross target; a native GPU build or a CPU cross build is untouched.
cuda_cross_active() {
  command -v cross_build_is_active >/dev/null 2>&1 && cross_build_is_active || return 1
  [ -f "$(cuda_cross_env_file)" ] || return 1
  return 0
}

# Exports the descriptor and what CMake reads from the environment: CUDAHOSTCXX (-ccbin) and -target-dir for every nvcc call.
cuda_cross_load() {
  cuda_cross_active || return 0
  [ -n "${CUDA_CROSS_TARGET_DIR:-}" ] && [ -n "${CUDAHOSTCXX:-}" ] && return 0
  # shellcheck disable=SC1090 # the gpu stage wrote it
  source "$(cuda_cross_env_file)"
  export CUDA_CROSS_TARGET_DIR CUDA_CROSS_TARGET_ARCH CUDA_CROSS_TARGET_TRIPLET CUDA_CROSS_TARGET_STAGING \
         CUDA_CROSS_TARGET_ROOT CUDA_CROSS_STUB_LIBCUDA CUDA_CROSS_CUDNN_HOME CUDA_CROSS_TENSORRT_HOME
  [ -n "${CXX:-}" ] || { echo "[ERROR] cuda_cross_load: CXX is unset; call setup_linux_cross_env first" >&2; return 1; }
  export CUDAHOSTCXX="${CXX}"
  # CMake's classic FindCUDA (OpenCV) derives nothing from nvcc when cross-compiling: it takes the root from this env and then knows sbsa-linux.
  export CUDA_TOOLKIT_ROOT="${CUDA_HOME:-/usr/local/cuda}"
  # Same module: cross-compiling it searches only the target dir and this env, and the driver stub sits in lib/stubs.
  export CUDA_LIB_PATH="${CUDA_CROSS_TARGET_ROOT}/lib/stubs"
  # The long = form: sccache's nvcc parser reads "-target-dir X" as a second input file and runs every kernel uncached (CON175, 2026-10-29).
  case " ${CUDAFLAGS:-} " in *" --target-directory="*) ;; *) export CUDAFLAGS="${CUDAFLAGS:+${CUDAFLAGS} }--target-directory=${CUDA_CROSS_TARGET_DIR}" ;; esac
  echo "[INFO] CUDA cross target ${CUDA_CROSS_TARGET_DIR} (${CUDA_CROSS_TARGET_ARCH}): CUDAHOSTCXX=${CUDAHOSTCXX}, CUDAFLAGS='${CUDAFLAGS}', cuDNN ${CUDA_CROSS_CUDNN_HOME}, TensorRT ${CUDA_CROSS_TENSORRT_HOME}"
}

# <array name>: the -D flags every CMake CUDA consumer needs beside append_cmake_cross_args (CMAKE_SYSTEM_PROCESSOR picks targets/<dir>).
append_cmake_cuda_cross_args() {
  local -n _acca_out="$1"
  cuda_cross_active || return 0
  cuda_cross_load || return 1
  _acca_out+=(
    # Named outright, as ORT's build.py does: OpenCV's check_language(CUDA) found no compiler under the cross toolchain (2026-10-28).
    "-DCMAKE_CUDA_COMPILER=${CUDA_HOME:-/usr/local/cuda}/bin/nvcc"
    "-DCMAKE_CUDA_HOST_COMPILER=${CXX}"
    "-DCUDAToolkit_ROOT=${CUDA_HOME:-/usr/local/cuda}"
    # The driver stub the target links without a GPU present; build.py and OpenCV default to the host's lib64/stubs.
    "-DCUDA_CUDA_LIBRARY=${CUDA_CROSS_STUB_LIBCUDA}"
  )
}
