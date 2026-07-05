#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

source_build_acceleration_helpers

parse_common_args "$@"
detect_jobs

# Early exit check
[[ "${BUILD_NATIVE_CPU}" != "true" ]] && {
  info "Skipping native CPU build"
  exit 0
}

# Install dependencies
if [ "${SKIP_DEP_INSTALL:-false}" != "true" ]; then
    if command -v sudo >/dev/null 2>&1; then
        sudo apt-get update && sudo apt-get install -y libgcc-s1
    else
        apt-get update && apt-get install -y libgcc-s1
    fi
fi

if command -v setup_linux_cross_env >/dev/null 2>&1; then
  setup_linux_cross_env
fi

# Create Python virtual environment with uv
: "${ORT_PYTHON_VERSION:=$(host_python_major_minor)}"
setup_host_python_environment
HOST_PYTHON="${HOST_PYTHON_BIN}"
info "Using existing Python virtual environment (expected at /opt/python/.venv)"

# Install Python build dependencies with uv
info "Installing Python build dependencies (numpy, wheel, setuptools)"
ensure_uv_python_packages "${HOST_PYTHON}" numpy wheel setuptools

# Validate build script exists
BUILD_SH="${ORT_SRC_DIR}/build.sh"
[[ -x "${BUILD_SH}" ]] || err "build.sh not found at ${BUILD_SH}"

info ">>> Native CPU build: ${NATIVE_CPU_CONFIG} (${JOBS} parallel jobs)"
info "Using Python: ${HOST_PYTHON}"
info "NumPy version: $(${HOST_PYTHON} -c 'import numpy; print(numpy.__version__)')"

# Prepare directories
ensure_onnx_output_tree "${NATIVE_CPU_OUTPUT_DIR}"

BUILD_ARGS=()
append_onnx_native_base_build_args BUILD_ARGS "${NATIVE_CPU_BUILD_DIR}" "${NATIVE_CPU_CONFIG}" "${JOBS}"
BUILD_ARGS+=(--use_xnnpack)

BUILD_ARGS+=(
  --cmake_extra_defines
  "CMAKE_POLICY_VERSION_MINIMUM=${CMAKE_POLICY_VERSION_MINIMUM}"
)

append_onnx_optional_lto_webgpu_args BUILD_ARGS

# oneDNN (DNNL) CPU execution provider. BUILD_DNNL_EP defaults to true (see
# lib/common.sh) but the --use_dnnl flag was never actually passed to build.py,
# so the EP was silently never built. Wire it up, gated to x86_64: oneDNN's
# kernels are x86-tuned and this is the native (host==target) build there.
if [ "${BUILD_DNNL_EP:-true}" = "true" ]; then
  case "${TARGET_ARCH:-${TARGETARCH:-}}" in
    amd64|x86_64)
      info "oneDNN (DNNL) execution provider enabled"
      BUILD_ARGS+=(--use_dnnl)
      ;;
    *)
      info "Skipping oneDNN EP (x86_64-only; arch=${TARGET_ARCH:-${TARGETARCH:-unknown}})"
      ;;
  esac
fi

# NOTE: no Arm NN execution provider here. ONNX Runtime deprecated (~1.16) and
# then removed the Arm NN EP; v1.27.0's build.py rejects --use_armnn/--armnn_home
# ("unrecognized arguments"), which hard-failed the build wherever /opt/armnn was
# present. The Arm NN / ACL libraries are still built and shipped (Dockerfile.media
# armnn stage) for direct use by the application, just not wired as an ORT EP.

if cross_build_is_active; then
  append_onnx_cross_cmake_build_args BUILD_ARGS
  if command -v cross_target_python_dev_ready >/dev/null 2>&1 && cross_target_python_dev_ready; then
    info "Target Python dev files available; enabling ONNX Runtime wheel build in cross mode"
    BUILD_ARGS+=(--build_wheel)
  else
    info "Skipping ONNX Runtime wheel build in cross mode; target Python headers/wheels are not safely buildable in the amd64 host container"
  fi
else
  BUILD_ARGS+=(--build_wheel)
fi

append_onnx_lld_build_args BUILD_ARGS
append_onnx_ccache_build_args BUILD_ARGS

# Ensure the venv Python is used for the ORT build (numpy is installed there, not in system python)
BUILD_ARGS+=(
  --cmake_extra_defines
  "Python_EXECUTABLE=${HOST_PYTHON_BIN}"
)
export PATH="${HOST_PYTHON_BIN%/*}:${PATH}"

# GCC 16.1.0 is the default system compiler (via ENV CC/CXX and alternatives)

# Execute build (with retry for transient network errors like GitHub download failures)
if ! retry 3 10 "ONNX Runtime CPU build" "${BUILD_SH}" "${BUILD_ARGS[@]}"; then
  if cross_build_is_active; then
    warn "ONNX Runtime build failed; rerunning single-threaded verbose build for diagnostics"
    cmake --build "${NATIVE_CPU_BUILD_DIR}/${NATIVE_CPU_CONFIG}" --config "${NATIVE_CPU_CONFIG}" --parallel 1 --verbose || true
  fi
  exit 1
fi

collect_wheels_from_tree "${NATIVE_CPU_BUILD_DIR}" "${NATIVE_CPU_OUTPUT_DIR}" "ONNX Runtime wheel"

# Additionally, try building a wheel from source if the ORT build did not produce one
if [ -z "$(ls -A "${NATIVE_CPU_OUTPUT_DIR}/wheels" 2>/dev/null || true)" ] && { ! cross_build_is_active; }; then
  maybe_build_source_wheel "${ORT_SRC_DIR}" "${NATIVE_CPU_OUTPUT_DIR}" "${HOST_PYTHON}" "ONNX Runtime"
fi

copy_onnx_headers_to_output "${NATIVE_CPU_OUTPUT_DIR}" "${ORT_SRC_DIR}" "${NATIVE_CPU_BUILD_DIR}"
info "Listing copied headers:"
ls -la "${NATIVE_CPU_OUTPUT_DIR}/include/"*.h 2>/dev/null || warn "No .h files found in include directory"

finalize_onnx_native_output "${NATIVE_CPU_BUILD_DIR}" "${NATIVE_CPU_CONFIG}" "${NATIVE_CPU_OUTPUT_DIR}" "${ORT_SRC_DIR}"

info "Build complete. Artifacts in ${NATIVE_CPU_OUTPUT_DIR}"
info "Wheels in ${NATIVE_CPU_OUTPUT_DIR}/wheels"
ls -lh "${NATIVE_CPU_OUTPUT_DIR}/wheels"/*.whl 2>/dev/null || true
find "${NATIVE_CPU_OUTPUT_DIR}/lib" -maxdepth 1 -type f -name "*.so*" -printf '%f\n' 2>/dev/null | head -20 || true

# Validation step
lib_dir="${NATIVE_CPU_OUTPUT_DIR}/lib"
if [ ! -d "${lib_dir}" ]; then
    echo "ERROR: ONNX Runtime lib directory not found: ${lib_dir}"
    exit 1
fi
shopt -s nullglob
libs_found=("${lib_dir}"/*.so*)
shopt -u nullglob
if [ "${#libs_found[@]}" -eq 0 ]; then
    echo "ERROR: No .so files found in ${lib_dir}"
    ls -la "${lib_dir}" || true
    exit 1
fi
echo "ONNX Runtime native build verified:"
ls -la "${lib_dir}"
