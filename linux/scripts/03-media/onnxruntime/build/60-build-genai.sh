#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

parse_common_args "$@"
detect_jobs

# Early exit check - ensure output dir exists even when skipping so Docker
# COPY --from=onnxruntime won't fail when the GenAI build is intentionally
# skipped (e.g. BUILD_GENAI=false).
[[ "${BUILD_GENAI}" != "true" ]] && {
  info "Skipping GenAI build (BUILD_GENAI=${BUILD_GENAI})"
  mkdir -p "${GENAI_OUTPUT_DIR}" "${GENAI_OUTPUT_DIR}/lib" "${GENAI_OUTPUT_DIR}/include" "${GENAI_OUTPUT_DIR}/wheels" || true
  echo "[INFO] Created placeholder GenAI output dir: ${GENAI_OUTPUT_DIR}" || true
  exit 0
}

# Architecture guard: GenAI is not supported on riscv64. If we're building on
# riscv64, skip this stage with an informative message so the overall image
# build can continue.
ARCH="$(arch_oci 2>/dev/null || uname -m 2>/dev/null || echo unknown)"
if [ "${ARCH}" = "riscv64" ] || [ "${ARCH}" = "risc-v" ]; then
  info "Skipping onnxruntime-genai on ${ARCH} because it is not supported"
  # Create placeholder output directories so later Dockerfile COPYs succeed
  mkdir -p "${GENAI_OUTPUT_DIR}" "${GENAI_OUTPUT_DIR}/lib" "${GENAI_OUTPUT_DIR}/include" "${GENAI_OUTPUT_DIR}/wheels" || true
  echo "[INFO] Created placeholder GenAI output dir for unsupported arch: ${GENAI_OUTPUT_DIR}" || true
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
if [[ ! -e "${NATIVE_CPU_OUTPUT_DIR}/lib/libonnxruntime.so" ]] && [[ ! -L "${NATIVE_CPU_OUTPUT_DIR}/lib/libonnxruntime.so" ]]; then
  warn "libonnxruntime.so symlink not found, checking for versioned libraries..."
  # Try to create symlink from versioned library
  versioned_lib="$(find "${NATIVE_CPU_OUTPUT_DIR}/lib" -maxdepth 1 -name 'libonnxruntime.so.*' -type f | head -1)"
  if [[ -n "${versioned_lib}" ]]; then
    ln -sf "$(basename "${versioned_lib}")" "${NATIVE_CPU_OUTPUT_DIR}/lib/libonnxruntime.so"
    info "Created symlink: ${NATIVE_CPU_OUTPUT_DIR}/lib/libonnxruntime.so -> $(basename "${versioned_lib}")"
  else
    err "No libonnxruntime.so* files found in ${NATIVE_CPU_OUTPUT_DIR}/lib"
  fi
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
uv pip install pip numpy wheel setuptools requests

info "Using Python: $(which python3)"
info "NumPy version: $(python3 -c 'import numpy; print(numpy.__version__)')"

# Prepare output directories
mkdir -p "${GENAI_OUTPUT_DIR}"/{lib,include,wheels}

# Build GenAI
cd "${GENAI_SRC_DIR}"

if [ "${ENABLE_NVIDIA:-false}" = "true" ]; then
  ORT_HOME="${NATIVE_GPU_OUTPUT_DIR:-/usr/local/lib/onnxruntime-gpu}"
  info "Building onnxruntime-genai with GPU ORT from ${ORT_HOME}"

  # Ensure libonnxruntime.so exists in the GPU ORT home (often it's just versioned)
  if [[ ! -e "${ORT_HOME}/lib/libonnxruntime.so" ]] && [[ ! -L "${ORT_HOME}/lib/libonnxruntime.so" ]]; then
    warn "libonnxruntime.so not found in ${ORT_HOME}/lib, attempting to create symlink..."
    versioned_lib="$(find "${ORT_HOME}/lib" -maxdepth 1 -name 'libonnxruntime.so.*' -type f | head -1)"
    if [[ -n "${versioned_lib}" ]]; then
      ln -sf "$(basename "${versioned_lib}")" "${ORT_HOME}/lib/libonnxruntime.so"
      info "Created symlink: ${ORT_HOME}/lib/libonnxruntime.so -> $(basename "${versioned_lib}")"
    else
      warn "No versioned libonnxruntime.so found in ${ORT_HOME}/lib!"
    fi
  fi

  python3 build.py \
    --config "${GENAI_CONFIG}" \
    --ort_home "${ORT_HOME}" \
    --parallel \
    --skip_tests \
    --skip_examples \
    --use_cuda \
    --cuda_home "${CUDA_HOME:-/usr/local/cuda}" \
    --use_trt_rtx \
    --use_guidance
else
  ORT_HOME="${NATIVE_CPU_OUTPUT_DIR}"
  info "Building onnxruntime-genai with CPU ORT from ${ORT_HOME}"

  python3 build.py \
    --config "${GENAI_CONFIG}" \
    --ort_home "${ORT_HOME}" \
    --parallel \
    --skip_tests \
    --skip_examples \
    --use_guidance
fi

# Copy wheel files
info "Searching for GenAI wheel files..."
find "${GENAI_SRC_DIR}/build" -name "*.whl" -type f 2>/dev/null | while read -r whl; do
  info "Copying wheel: ${whl}"
  cp "${whl}" "${GENAI_OUTPUT_DIR}/wheels/"
  ls -lh "${GENAI_OUTPUT_DIR}/wheels/$(basename "${whl}")"
done || info "No wheels found in ${GENAI_SRC_DIR}/build"

# If no GenAI wheels were created, attempt to build a wheel from the GenAI Python package
if [ -z "$(ls -A "${GENAI_OUTPUT_DIR}/wheels" 2>/dev/null || true)" ]; then
  info "No GenAI wheels found; attempting pip wheel build from source"
  if [ -f "${GENAI_SRC_DIR}/pyproject.toml" ] || [ -f "${GENAI_SRC_DIR}/setup.py" ]; then
    mkdir -p "${GENAI_OUTPUT_DIR}/wheels"
    python3 -m pip wheel -w "${GENAI_OUTPUT_DIR}/wheels" "${GENAI_SRC_DIR}" || info "pip wheel failed for GenAI source"
    info "Wheels after pip wheel:"; ls -lh "${GENAI_OUTPUT_DIR}/wheels"/*.whl 2>/dev/null || true
  else
    info "GenAI python packaging not detected; skipping pip wheel"
  fi
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

# Create symlinks in /usr/local/lib
find "${GENAI_OUTPUT_DIR}/lib" -type f -name "lib*.so*" -print0 2>/dev/null | \
  xargs -0 -r ln -sf -t /usr/local/lib/ 2>/dev/null || true

ldconfig 2>/dev/null || true

info "GenAI build complete. Artifacts in ${GENAI_OUTPUT_DIR}"
info "Wheels in ${GENAI_OUTPUT_DIR}/wheels"
ls -lh "${GENAI_OUTPUT_DIR}/wheels"/*.whl 2>/dev/null || true
ls -lh "${GENAI_OUTPUT_DIR}/lib"/*.so* 2>/dev/null | head -20 || true
