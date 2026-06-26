#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

parse_common_args "$@"
detect_jobs

setup_host_python_environment
HOST_PYTHON="${HOST_PYTHON_BIN}"

# Early exit check - ensure output dir exists even when skipping so Docker
# COPY --from=onnxruntime won't fail when the GenAI build is intentionally
# skipped (e.g. BUILD_GENAI=false).
[[ "${BUILD_GENAI}" != "true" ]] && {
  info "Skipping GenAI build (BUILD_GENAI=${BUILD_GENAI})"
  ensure_onnx_output_tree "${GENAI_OUTPUT_DIR}"
  echo "[INFO] Created placeholder GenAI output dir: ${GENAI_OUTPUT_DIR}"
  exit 0
}

# Architecture guard: GenAI is not supported on riscv64. If we're building on
# riscv64, skip this stage with an informative message so the overall image
# build can continue.
ARCH="$(arch_oci 2>/dev/null || uname -m 2>/dev/null || echo unknown)"
if [ "${ARCH}" = "riscv64" ] || [ "${ARCH}" = "risc-v" ]; then
  info "Skipping onnxruntime-genai on ${ARCH} because it is not supported"
  # Create placeholder output directories so later Dockerfile COPYs succeed
  ensure_onnx_output_tree "${GENAI_OUTPUT_DIR}"
  echo "[INFO] Created placeholder GenAI output dir for unsupported arch: ${GENAI_OUTPUT_DIR}" || true
  exit 0
fi

if cross_build_is_active; then
  info "Skipping onnxruntime-genai in cross mode; the build emits target wheels and host-run validation"
  ensure_onnx_output_tree "${GENAI_OUTPUT_DIR}"
  exit 0
fi

# Validate native CPU build completed (GenAI depends on ORT)
info "Checking for ONNX Runtime at: ${NATIVE_CPU_OUTPUT_DIR}"
info "NATIVE_CPU_OUTPUT_DIR=${NATIVE_CPU_OUTPUT_DIR}"

if [[ ! -d "${NATIVE_CPU_OUTPUT_DIR}/lib" ]]; then
  err "Native CPU build lib directory not found at ${NATIVE_CPU_OUTPUT_DIR}/lib. Run 30-build-native.sh first."
fi

info "Contents of ${NATIVE_CPU_OUTPUT_DIR}/lib:"
ls -la "${NATIVE_CPU_OUTPUT_DIR}/lib/" || true

if [[ -z "$(ls -A "${NATIVE_CPU_OUTPUT_DIR}/lib"/*.so* 2>/dev/null)" ]]; then
  err "No .so files found in ${NATIVE_CPU_OUTPUT_DIR}/lib. Run 30-build-native.sh first."
fi

# Check specifically for libonnxruntime.so (may be a symlink)
ensure_onnxruntime_symlink "${NATIVE_CPU_OUTPUT_DIR}"
if [[ ! -e "${NATIVE_CPU_OUTPUT_DIR}/lib/libonnxruntime.so" ]] && [[ ! -L "${NATIVE_CPU_OUTPUT_DIR}/lib/libonnxruntime.so" ]]; then
  err "No libonnxruntime.so* files found in ${NATIVE_CPU_OUTPUT_DIR}/lib"
fi

# Check for required header
if [[ ! -f "${NATIVE_CPU_OUTPUT_DIR}/include/onnxruntime_c_api.h" ]]; then
  err "ONNX Runtime header not found at ${NATIVE_CPU_OUTPUT_DIR}/include/onnxruntime_c_api.h. Run 30-build-native.sh first."
fi
info "Found onnxruntime_c_api.h at ${NATIVE_CPU_OUTPUT_DIR}/include/onnxruntime_c_api.h"

# Check GenAI source exists
[[ -d "${GENAI_SRC_DIR}" ]] || err "GenAI source not found at ${GENAI_SRC_DIR}. Run 20-fetch.sh first."

info ">>> GenAI build: ${GENAI_CONFIG} (${JOBS} parallel jobs)"

# Create Python virtual environment with uv
info "Using existing Python virtual environment (expected at /opt/python/.venv)"

# Install Python build dependencies with uv
info "Installing Python build dependencies (pip, numpy, wheel, setuptools, requests)"
ensure_uv_python_packages "${HOST_PYTHON}" pip numpy wheel setuptools requests

info "Using Python: ${HOST_PYTHON}"
info "NumPy version: $(${HOST_PYTHON} -c 'import numpy; print(numpy.__version__)')"

# Prepare output directories
ensure_onnx_output_tree "${GENAI_OUTPUT_DIR}"

# Build GenAI
cd "${GENAI_SRC_DIR}"

# Shared build acceleration (lld + ccache) — same flags as the CPU build
append_onnx_lld_build_args BUILD_ARGS || true
append_onnx_ccache_build_args BUILD_ARGS || true

# Common base args shared between GPU and CPU builds
GENAI_BASE_ARGS=(
  --config "${GENAI_CONFIG}"
  --skip_tests
  --skip_examples
  --use_guidance
  --cmake_extra_defines
  "CMAKE_POLICY_VERSION_MINIMUM=${CMAKE_POLICY_VERSION_MINIMUM}"
)

if [ "${ENABLE_NVIDIA:-false}" = "true" ]; then
  ORT_HOME="${NATIVE_GPU_OUTPUT_DIR:-/usr/local/lib/onnxruntime-gpu}"
  info "Building onnxruntime-genai with GPU ORT from ${ORT_HOME}"

  ensure_onnxruntime_symlink "${ORT_HOME}"
  if [[ ! -e "${ORT_HOME}/lib/libonnxruntime.so" ]] && [[ ! -L "${ORT_HOME}/lib/libonnxruntime.so" ]]; then
    warn "No versioned libonnxruntime.so found in ${ORT_HOME}/lib"
  fi

  info "GenAI build args: ${GENAI_BASE_ARGS[*]}"
  retry 3 10 "ONNX Runtime GenAI GPU build" "${HOST_PYTHON}" build.py \
    "${GENAI_BASE_ARGS[@]}" \
    --ort_home "${ORT_HOME}" \
    --use_cuda \
    --cuda_home "${CUDA_HOME:-/usr/local/cuda}" \
    --use_trt_rtx
else
  ORT_HOME="${NATIVE_CPU_OUTPUT_DIR}"
  info "Building onnxruntime-genai with CPU ORT from ${ORT_HOME}"

  info "GenAI build args: ${GENAI_BASE_ARGS[*]}"
  retry 3 10 "ONNX Runtime GenAI CPU build" "${HOST_PYTHON}" build.py \
    "${GENAI_BASE_ARGS[@]}" \
    --ort_home "${ORT_HOME}"
fi

collect_wheels_from_tree "${GENAI_SRC_DIR}/build" "${GENAI_OUTPUT_DIR}" "GenAI wheel"

# If no GenAI wheels were created, attempt to build a wheel from the GenAI Python package
if [ -z "$(ls -A "${GENAI_OUTPUT_DIR}/wheels" 2>/dev/null || true)" ]; then
  maybe_build_source_wheel "${GENAI_SRC_DIR}" "${GENAI_OUTPUT_DIR}" "${HOST_PYTHON}" "GenAI"
fi

# Copy headers
if [[ -f "${GENAI_SRC_DIR}/src/ort_genai.h" ]]; then
  cp "${GENAI_SRC_DIR}/src/ort_genai.h" "${GENAI_OUTPUT_DIR}/include/"
  cp "${GENAI_SRC_DIR}/src/ort_genai_c.h" "${GENAI_OUTPUT_DIR}/include/" 2>/dev/null || true
  info "Copied GenAI headers to ${GENAI_OUTPUT_DIR}/include/"
else
  warn "GenAI headers not found at ${GENAI_SRC_DIR}/src/"
fi

# Copy libraries
# GenAI builds to build/Linux/Release/ (or similar based on config)
GENAI_LIB_DIR="${GENAI_SRC_DIR}/build/Linux/${GENAI_CONFIG}"
if [[ -d "${GENAI_LIB_DIR}" ]]; then
  find "${GENAI_LIB_DIR}" -maxdepth 1 -type f \
    \( -name "libonnxruntime-genai*.so*" -o -name "*.so" \) \
    -exec cp -t "${GENAI_OUTPUT_DIR}/lib/" {} + 2>/dev/null || true
fi

symlink_output_libraries_into_usr_local "${GENAI_OUTPUT_DIR}"

info "GenAI build complete. Artifacts in ${GENAI_OUTPUT_DIR}"
info "Wheels in ${GENAI_OUTPUT_DIR}/wheels"
ls -lh "${GENAI_OUTPUT_DIR}/wheels"/*.whl 2>/dev/null || true
find "${GENAI_OUTPUT_DIR}/lib" -maxdepth 1 -type f -name "*.so*" -printf '%f\n' 2>/dev/null | head -20 || true
