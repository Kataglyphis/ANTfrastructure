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

sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends libgcc-s1

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
# HIP compile caching (sccache) — same gated pattern as the CUDA/Rust wiring;
# sccache wraps hipcc/clang-hip, ccache does not. Validate with
# ENABLE_SCCACHE_CUDA=1 (one gate for both GPU compiler families), then flip.
if [ "${ENABLE_SCCACHE_CUDA:-0}" = "1" ] && command -v sccache >/dev/null 2>&1; then
  info "sccache: wrapping HIP via CMAKE_HIP_COMPILER_LAUNCHER"
  BUILD_ARGS+=(--cmake_extra_defines "CMAKE_HIP_COMPILER_LAUNCHER=sccache")
fi

BUILD_ARGS+=(
  --use_migraphx
  --migraphx_home "${MIGRAPHX_HOME}"
)

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

info "AMD GPU build complete. Artifacts in ${NATIVE_GPU_OUTPUT_DIR}"
info "Wheels in ${NATIVE_GPU_OUTPUT_DIR}/wheels"
ls -lh "${NATIVE_GPU_OUTPUT_DIR}/wheels"/*.whl 2>/dev/null || true
find "${NATIVE_GPU_OUTPUT_DIR}/lib" -maxdepth 1 -type f -name "*.so*" -printf '%f\n' 2>/dev/null | sed -n '1,20p' || true
