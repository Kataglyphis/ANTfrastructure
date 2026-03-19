#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

parse_common_args "$@"
detect_jobs

# Early exit check
[[ "${BUILD_NATIVE_CPU}" != "true" ]] && {
  info "Skipping native CPU build"
  exit 0
}

# Install dependencies
sudo apt-get update && sudo apt-get install -y libgcc-s1

# Create Python virtual environment with uv
VENV_DIR="${NATIVE_CPU_BUILD_DIR}/venv"
info "Creating Python virtual environment with uv at ${VENV_DIR}"
mkdir -p "$(dirname "${VENV_DIR}")"
uv venv "${VENV_DIR}"
source "${VENV_DIR}/bin/activate"

# Install Python build dependencies with uv
info "Installing Python build dependencies (numpy, wheel, setuptools)"
uv pip install numpy wheel setuptools

# Validate build script exists
BUILD_SH="${ORT_SRC_DIR}/build.sh"
[[ -x "${BUILD_SH}" ]] || err "build.sh not found at ${BUILD_SH}"

info ">>> Native CPU build: ${NATIVE_CPU_CONFIG} (${JOBS} parallel jobs)"
info "Using Python: $(which python3)"
info "NumPy version: $(python3 -c 'import numpy; print(numpy.__version__)')"

# Prepare directories
mkdir -p "${NATIVE_CPU_OUTPUT_DIR}"/{lib,include,wheels}

# Execute build
"${BUILD_SH}" \
  --build_dir "${NATIVE_CPU_BUILD_DIR}" \
  --config "${NATIVE_CPU_CONFIG}" \
  --build_shared_lib \
  --parallel "${JOBS}" \
  --build_wheel \
  --compile_no_warning_as_error \
  --skip_submodule_sync \
  --skip_tests \
  --allow_running_as_root

# Deactivate virtual environment
deactivate

# Copy wheel files
info "Searching for wheel files..."
find "${NATIVE_CPU_BUILD_DIR}" -name "*.whl" -type f 2>/dev/null | while read -r whl; do
  info "Copying wheel: ${whl}"
  cp "${whl}" "${NATIVE_CPU_OUTPUT_DIR}/wheels/"
  ls -lh "${NATIVE_CPU_OUTPUT_DIR}/wheels/$(basename "${whl}")"
done || info "No wheels found in ${NATIVE_CPU_BUILD_DIR}"

# Copy headers
cp -a "${ORT_SRC_DIR}/include" "${NATIVE_CPU_OUTPUT_DIR}/" 2>/dev/null || \
  warn "Include directory not found at ${ORT_SRC_DIR}/include"

# Copy libraries
mkdir -p "${NATIVE_CPU_OUTPUT_DIR}/lib"
find "${NATIVE_CPU_BUILD_DIR}/${NATIVE_CPU_CONFIG}" -maxdepth 1 -type f \
  \( -name "libonnxruntime*.so*" -o -name "libonnxruntime_providers_*.so*" \) \
  -exec cp -t "${NATIVE_CPU_OUTPUT_DIR}/lib/" {} + 2>/dev/null || true

# Create unversioned symlink for libonnxruntime.so (required by GenAI CMake)
onnx_lib="$(find "${NATIVE_CPU_OUTPUT_DIR}/lib" -maxdepth 1 -name 'libonnxruntime.so.*' -type f | head -1)"
if [[ -n "${onnx_lib}" ]] && [[ ! -e "${NATIVE_CPU_OUTPUT_DIR}/lib/libonnxruntime.so" ]]; then
  ln -sf "$(basename "${onnx_lib}")" "${NATIVE_CPU_OUTPUT_DIR}/lib/libonnxruntime.so"
  info "Created symlink: libonnxruntime.so -> $(basename "${onnx_lib}")"
fi

# Create symlinks in /usr/local/lib
find "${NATIVE_CPU_OUTPUT_DIR}/lib" -type f -name "lib*.so*" -print0 2>/dev/null | \
  xargs -0 -r ln -sf -t /usr/local/lib/ 2>/dev/null || true

ldconfig 2>/dev/null || true

info "Build complete. Artifacts in ${NATIVE_CPU_OUTPUT_DIR}"
info "Wheels in ${NATIVE_CPU_OUTPUT_DIR}/wheels"
ls -lh "${NATIVE_CPU_OUTPUT_DIR}/wheels"/*.whl 2>/dev/null || true
ls -lh "${NATIVE_CPU_OUTPUT_DIR}/lib"/*.so* 2>/dev/null | head -20 || true
