#!/usr/bin/env bash
# ==============================================================================
# 30-build-native-amd.sh
# Build ONNX Runtime with the ROCm execution provider.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

source_build_acceleration_helpers

parse_common_args "$@"
detect_jobs

ROCM_HOME="${ROCM_HOME:-/usr}"
ROCM_VERSION="${ROCM_VERSION:-7.1}"
NATIVE_GPU_OUTPUT_DIR="${NATIVE_GPU_OUTPUT_DIR:-/usr/local/lib/onnxruntime-gpu}"
NATIVE_GPU_BUILD_DIR="${NATIVE_GPU_BUILD_DIR:-${ORT_SRC_DIR}/build_native_gpu_rocm}"

if ! command -v hipcc >/dev/null 2>&1 && [ ! -d "${ROCM_HOME}/lib/rocm" ]; then
  err "ROCm not found. Install the AMD toolchain layer first or set ROCM_HOME."
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
  warn "Skipping ONNX Runtime ROCm wheel build in cross mode; target wheel repair/validation is not supported here"
fi

info ">>> Native AMD GPU build (ROCm): ${NATIVE_CPU_CONFIG} (${JOBS} parallel jobs)"
info "Using Python: ${HOST_PYTHON}"
info "NumPy version: $(${HOST_PYTHON} -c 'import numpy; print(numpy.__version__)')"

ensure_onnx_output_tree "${NATIVE_GPU_OUTPUT_DIR}"

BUILD_ARGS=(
  --build_dir "${NATIVE_GPU_BUILD_DIR}"
  --config "${NATIVE_CPU_CONFIG}"
  --build_shared_lib
  --parallel "${JOBS}"
  --compile_no_warning_as_error
  --skip_submodule_sync
  --skip_tests
  --allow_running_as_root
  --use_rocm
  --rocm_home "${ROCM_HOME}"
  --rocm_version "${ROCM_VERSION}"
  --use_mimalloc
  --use_lock_free_queue
)

BUILD_ARGS+=(
  --cmake_extra_defines
  "CMAKE_POLICY_VERSION_MINIMUM=${CMAKE_POLICY_VERSION_MINIMUM}"
)

if [ "${ORT_ENABLE_LTO:-false}" = "true" ]; then
  BUILD_ARGS+=(--enable_lto)
fi

if [ "${ORT_ENABLE_WEBGPU:-false}" = "true" ]; then
  BUILD_ARGS+=(
    --use_webgpu
    --use_external_dawn
  )
fi

if cross_build_is_active; then
  append_onnx_cross_cmake_build_args BUILD_ARGS
else
  BUILD_ARGS+=(--build_wheel)
fi

append_onnx_lld_build_args BUILD_ARGS
append_onnx_ccache_build_args BUILD_ARGS

export PATH="${ROCM_HOME}/bin:${PATH}"
export LD_LIBRARY_PATH="${ROCM_HOME}/lib/rocm/lib:${ROCM_HOME}/lib:${LD_LIBRARY_PATH:-}"

if ! "${BUILD_SH}" "${BUILD_ARGS[@]}"; then
  if cross_build_is_active; then
    warn "ONNX Runtime ROCm build failed; rerunning single-threaded verbose build for diagnostics"
    cmake --build "${NATIVE_GPU_BUILD_DIR}/${NATIVE_CPU_CONFIG}" --config "${NATIVE_CPU_CONFIG}" --parallel 1 --verbose || true
  fi
  exit 1
fi

info "Searching for ROCm wheel files..."
collect_wheels_from_tree "${NATIVE_GPU_BUILD_DIR}" "${NATIVE_GPU_OUTPUT_DIR}" "ROCm wheel"

if [ -z "$(ls -A "${NATIVE_GPU_OUTPUT_DIR}/wheels" 2>/dev/null || true)" ] && { ! cross_build_is_active; }; then
  maybe_build_source_wheel "${ORT_SRC_DIR}" "${NATIVE_GPU_OUTPUT_DIR}" "${HOST_PYTHON}" "ONNX Runtime ROCm"
fi

copy_onnx_headers_to_output "${NATIVE_GPU_OUTPUT_DIR}" "${ORT_SRC_DIR}" "${NATIVE_GPU_BUILD_DIR}"
verify_onnxruntime_core_header "${NATIVE_GPU_OUTPUT_DIR}" "${ORT_SRC_DIR}" "${NATIVE_GPU_BUILD_DIR}"
copy_onnx_libraries_to_output "${NATIVE_GPU_BUILD_DIR}" "${NATIVE_CPU_CONFIG}" "${NATIVE_GPU_OUTPUT_DIR}"
ensure_onnxruntime_symlink "${NATIVE_GPU_OUTPUT_DIR}"
symlink_output_libraries_into_usr_local "${NATIVE_GPU_OUTPUT_DIR}"

info "AMD GPU build complete. Artifacts in ${NATIVE_GPU_OUTPUT_DIR}"
info "Wheels in ${NATIVE_GPU_OUTPUT_DIR}/wheels"
ls -lh "${NATIVE_GPU_OUTPUT_DIR}/wheels"/*.whl 2>/dev/null || true
find "${NATIVE_GPU_OUTPUT_DIR}/lib" -maxdepth 1 -type f -name "*.so*" -printf '%f\n' 2>/dev/null | sed -n '1,20p' || true
