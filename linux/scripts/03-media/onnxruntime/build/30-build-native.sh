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
: "${ORT_PYTHON_VERSION:=3.14}"
VENV_DIR="${NATIVE_CPU_BUILD_DIR}/venv"
info "Creating Python virtual environment with uv at ${VENV_DIR} (python=${ORT_PYTHON_VERSION})"
mkdir -p "$(dirname "${VENV_DIR}")"
uv venv "${VENV_DIR}" --python "${ORT_PYTHON_VERSION}"
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

# Additionally, try building a wheel from source if the ORT build did not produce one
if [ -z "$(ls -A "${NATIVE_CPU_OUTPUT_DIR}/wheels" 2>/dev/null || true)" ]; then
  info "No wheels found from ONNX Runtime build; attempting to build wheel via pip"
  if [ -f "${ORT_SRC_DIR}/pyproject.toml" ] || [ -f "${ORT_SRC_DIR}/setup.py" ]; then
    info "Building wheel from ORT python package"
    mkdir -p "${NATIVE_CPU_OUTPUT_DIR}/wheels"
    python -m pip wheel -w "${NATIVE_CPU_OUTPUT_DIR}/wheels" "${ORT_SRC_DIR}" || info "pip wheel failed for ORT source"
    info "Wheels after pip wheel:"; ls -lh "${NATIVE_CPU_OUTPUT_DIR}/wheels"/*.whl 2>/dev/null || true
  else
    info "ORT python packaging not detected; skipping pip wheel"
  fi
fi

# Copy headers from source
mkdir -p "${NATIVE_CPU_OUTPUT_DIR}/include"
if [[ -d "${ORT_SRC_DIR}/include" ]]; then
  cp -a "${ORT_SRC_DIR}/include/." "${NATIVE_CPU_OUTPUT_DIR}/include/" 2>/dev/null || true
  info "Copied headers from ${ORT_SRC_DIR}/include"
fi

# Copy generated headers from build directory
if [[ -d "${NATIVE_CPU_BUILD_DIR}/include" ]]; then
  cp -a "${NATIVE_CPU_BUILD_DIR}/include/." "${NATIVE_CPU_OUTPUT_DIR}/include/" 2>/dev/null || true
  info "Copied generated headers from ${NATIVE_CPU_BUILD_DIR}/include"
fi

# Flatten headers for GenAI - it expects headers at include/ root
# ONNX Runtime has them at include/onnxruntime/core/session/
for search_dir in "${ORT_SRC_DIR}" "${NATIVE_CPU_BUILD_DIR}"; do
  if [[ ! -d "${search_dir}/include" ]]; then
    continue
  fi
  # Copy all ONNX Runtime C API header files from nested directories to include root
  find "${search_dir}/include" -name "onnxruntime*.h" -type f 2>/dev/null | while read -r hdr; do
    cp "${hdr}" "${NATIVE_CPU_OUTPUT_DIR}/include/" 2>/dev/null || true
  done
done
info "Listing copied headers:"
ls -la "${NATIVE_CPU_OUTPUT_DIR}/include/"*.h 2>/dev/null || warn "No .h files found in include directory"

# Verify critical headers
if [[ -f "${NATIVE_CPU_OUTPUT_DIR}/include/onnxruntime_c_api.h" ]]; then
  info "Found onnxruntime_c_api.h in include directory"
else
  warn "onnxruntime_c_api.h not found - GenAI build may fail"
  warn "Searching for onnxruntime_c_api.h..."
  find "${ORT_SRC_DIR}" -name "onnxruntime_c_api.h" 2>/dev/null | head -5 || true
  find "${NATIVE_CPU_BUILD_DIR}" -name "onnxruntime_c_api.h" 2>/dev/null | head -5 || true
fi

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

# Validation step
lib_dir="${NATIVE_CPU_OUTPUT_DIR}/lib"
if [ ! -d "${lib_dir}" ]; then
    echo "ERROR: ONNX Runtime lib directory not found: ${lib_dir}"
    exit 1
fi
if [ -z "$(ls -A ${lib_dir}/*.so* 2>/dev/null)" ]; then
    echo "ERROR: No .so files found in ${lib_dir}"
    ls -la "${lib_dir}" || true
    exit 1
fi
echo "ONNX Runtime native build verified:"
ls -la "${lib_dir}"
