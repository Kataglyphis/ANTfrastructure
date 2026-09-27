#!/usr/bin/env bash
# ==============================================================================
# 30-build-native-amd.sh
# Build ONNX Runtime with the MIGraphX execution provider.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

source_build_acceleration_helpers

parse_common_args "$@"
detect_jobs

MIGRAPHX_HOME="${MIGRAPHX_HOME:-/opt/rocm}"
MIGRAPHX_VERSION="${MIGRAPHX_VERSION:-2.14.0}"
NATIVE_GPU_OUTPUT_DIR="${NATIVE_GPU_OUTPUT_DIR:-/usr/local/lib/onnxruntime-gpu}"
NATIVE_GPU_BUILD_DIR="${NATIVE_GPU_BUILD_DIR:-${ORT_SRC_DIR}/build_native_gpu_migraphx}"

if ! command -v hipcc >/dev/null 2>&1 && [ ! -d "${MIGRAPHX_HOME}/include/migraphx" ]; then
  err "MIGraphX not found. Install the AMD toolchain layer first or set MIGRAPHX_HOME."
fi

if command -v setup_linux_cross_env >/dev/null 2>&1; then
  setup_linux_cross_env
fi

if [ "${SKIP_DEP_INSTALL:-false}" != "true" ]; then
    # Guarded like the CPU step (30-build-native.sh): the media stage runs as
    # root in images where sudo is not necessarily installed — bare `sudo`
    # died rc 127 there while the CPU sibling degraded gracefully.
    if command -v sudo >/dev/null 2>&1; then
        sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends libgcc-s1
    else
        apt-get update -qq && apt-get install -y --no-install-recommends libgcc-s1
    fi
fi

: "${ORT_PYTHON_VERSION:=$(host_python_major_minor)}"
setup_host_python_environment
HOST_PYTHON="${HOST_PYTHON_BIN}"

info "Using existing Python virtual environment (expected at /opt/python/.venv)"
ensure_uv_python_packages "${HOST_PYTHON}" numpy wheel setuptools

BUILD_SH="${ORT_SRC_DIR}/build.sh"
[[ -x "${BUILD_SH}" ]] || err "build.sh not found at ${BUILD_SH}"

if cross_build_is_active; then
  warn "Skipping ONNX Runtime MIGraphX wheel build in cross mode; target wheel repair/validation is not supported here"
fi

info ">>> Native AMD GPU build (MIGraphX): ${NATIVE_CPU_CONFIG} (${JOBS} parallel jobs)"
info "Using Python: ${HOST_PYTHON}"
info "NumPy version: $(${HOST_PYTHON} -c 'import numpy; print(numpy.__version__)')"

ensure_onnx_output_tree "${NATIVE_GPU_OUTPUT_DIR}"

BUILD_ARGS=()
append_onnx_native_base_build_args BUILD_ARGS "${NATIVE_GPU_BUILD_DIR}" "${NATIVE_CPU_CONFIG}" "${JOBS}"
# TheRock splits ROCm into versioned subdirs (/opt/rocm/core-10.0/), so
# hipConfig.cmake sits only under core-<ver>/lib/cmake/hip — while ORT's
# onnxruntime_providers_migraphx.cmake probes flat prefixes only
# (/opt/rocm/hcc /opt/rocm/hip /opt/rocm $ENV{HIP_PATH}). Pin hip_DIR to the
# resolved config dir; see docs/linux-accelerator-images.md § ROCm.
_hip_config_dir="$(find "${MIGRAPHX_HOME}" -maxdepth 5 -path '*/lib/cmake/hip' -type d 2>/dev/null | sort | tail -1)"
if [ -n "${_hip_config_dir}" ] && [ -f "${_hip_config_dir}/hip-config.cmake" ]; then
  # migraphx-config.cmake find_dependency()s MIOpen/rocblas/hipblaslt, whose
  # own configs sit in the same versioned tree — every one of them is only
  # findable through the core-<ver>/lib/cmake prefix. Hand CMake the whole
  # prefix rather than pinning dirs one by one (proven: migraphx configures
  # with CMAKE_PREFIX_PATH=.../core-10.0/lib/cmake alone).
  _rocm_cmake_root="$(dirname "${_hip_config_dir}")"
  # The prefix that fixes hip/MIOpen/rocblas also exposes ROCm's OWN
  # flatbuffers (25.x), and ORT's FetchContent FIND_PACKAGE_ARGS then takes it
  # instead of building its pinned 23.5.26 — ort.fbs.h asserts == 23 and the
  # build dies mid-compile (run 20260927-115341). CMAKE_IGNORE_PREFIX_PATH
  # does not reach it; CMAKE_DISABLE_FIND_PACKAGE_<name> makes FetchContent
  # skip the find_package step and build the pinned copy. Container-proven.
  info "Pinning hip_DIR=${_hip_config_dir} + CMAKE_PREFIX_PATH=${_rocm_cmake_root}"
  BUILD_ARGS+=(
    --cmake_extra_defines "hip_DIR=${_hip_config_dir}"
    --cmake_extra_defines "CMAKE_PREFIX_PATH=${_rocm_cmake_root}"
    --cmake_extra_defines "CMAKE_DISABLE_FIND_PACKAGE_flatbuffers=TRUE"
  )
else
  warn "No hip-config.cmake under ${MIGRAPHX_HOME}; letting CMake search its defaults"
fi
# HIP compile caching — sccache wraps hipcc/clang-hip first-class (ccache cannot).
# Resolve through compiler_cache_launcher() for the guarded launcher;
# only accept sccache-class launchers (ccache can't wrap hipcc).
if [ "${ENABLE_SCCACHE_CUDA:-0}" = "1" ]; then
  compiler_cache_launcher_env 2>/dev/null || true
  _gpu_launcher="$(compiler_cache_launcher 2>/dev/null || true)"
  case "${_gpu_launcher}" in
    *sccache*)
      info "sccache: wrapping HIP via CMAKE_HIP_COMPILER_LAUNCHER (${_gpu_launcher})"
      BUILD_ARGS+=(--cmake_extra_defines "CMAKE_HIP_COMPILER_LAUNCHER=${_gpu_launcher}")
      ;;
    *)
      warn "sccache unavailable for HIP caching — building uncached"
      ;;
  esac
fi

BUILD_ARGS+=(
  --use_migraphx
  --migraphx_home "${MIGRAPHX_HOME}"
)

# Same reason as the CPU and NVIDIA builds: ORT 1.29 defaults telemetry ON for
# native Linux, pulling in cpp_client_telemetry's vendored sqlite, which dies on
# GCC 16's -Werror=stringop-overflow (sqlite3_retail.c:81192). Each native build
# script owns its own arg list, so the 2026-08-19 CPU fix never reached this one.
BUILD_ARGS+=(--no_telemetry)

BUILD_ARGS+=(
  --cmake_extra_defines
  "CMAKE_POLICY_VERSION_MINIMUM=${CMAKE_POLICY_VERSION_MINIMUM}"
)

append_onnx_optional_lto_webgpu_args BUILD_ARGS

if cross_build_is_active; then
  append_onnx_cross_cmake_build_args BUILD_ARGS
else
  BUILD_ARGS+=(--build_wheel)
fi

append_onnx_lld_build_args BUILD_ARGS
append_onnx_ccache_build_args BUILD_ARGS

export PATH="${MIGRAPHX_HOME}/bin:${PATH}"
export LD_LIBRARY_PATH="${MIGRAPHX_HOME}/lib:${MIGRAPHX_HOME}/lib64:${LD_LIBRARY_PATH:-}"

if ! "${BUILD_SH}" "${BUILD_ARGS[@]}"; then
  if cross_build_is_active; then
    warn "ONNX Runtime MIGraphX build failed; rerunning single-threaded verbose build for diagnostics"
    cmake --build "${NATIVE_GPU_BUILD_DIR}/${NATIVE_CPU_CONFIG}" --config "${NATIVE_CPU_CONFIG}" --parallel 1 --verbose || true
  fi
  exit 1
fi

info "Searching for MIGraphX wheel files..."
collect_wheels_from_tree "${NATIVE_GPU_BUILD_DIR}" "${NATIVE_GPU_OUTPUT_DIR}" "MIGraphX wheel"

if [ -z "$(ls -A "${NATIVE_GPU_OUTPUT_DIR}/wheels" 2>/dev/null || true)" ] && { ! cross_build_is_active; }; then
  maybe_build_source_wheel "${ORT_SRC_DIR}" "${NATIVE_GPU_OUTPUT_DIR}" "${HOST_PYTHON}" "ONNX Runtime MIGraphX"
fi

copy_onnx_headers_to_output "${NATIVE_GPU_OUTPUT_DIR}" "${ORT_SRC_DIR}" "${NATIVE_GPU_BUILD_DIR}"
finalize_onnx_native_output "${NATIVE_GPU_BUILD_DIR}" "${NATIVE_CPU_CONFIG}" "${NATIVE_GPU_OUTPUT_DIR}" "${ORT_SRC_DIR}"

report_onnx_build_output "AMD GPU build complete" "${NATIVE_GPU_OUTPUT_DIR}"
