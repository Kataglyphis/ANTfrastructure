#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Source build acceleration helpers if available
for helper in \
    "/opt/scripts/core/compiler-cache.sh" \
    "${SCRIPT_DIR}/../../../../01-core/compiler-cache.sh"; do
    if [ -f "${helper}" ]; then
        # shellcheck disable=SC1090
        source "${helper}"
        setup_ccache
        setup_lld_linker
        break
    fi
done

parse_common_args "$@"
detect_jobs

# Early exit check
[[ "${BUILD_NATIVE_CPU}" != "true" ]] && {
  info "Skipping native CPU build"
  exit 0
}

# Install dependencies
sudo apt-get update && sudo apt-get install -y libgcc-s1

if command -v setup_linux_cross_env >/dev/null 2>&1; then
  setup_linux_cross_env
fi

# Create Python virtual environment with uv
: "${ORT_PYTHON_VERSION:=${PYTHON_MAJOR_MINOR:-3.14}}"
HOST_PYTHON="$(host_python_bin)"
export PYTHON_EXECUTABLE="${HOST_PYTHON}" \
       Python_EXECUTABLE="${HOST_PYTHON}" \
       Python3_EXECUTABLE="${HOST_PYTHON}"
info "Using existing Python virtual environment (expected at /opt/python/.venv)"

# Install Python build dependencies with uv
info "Installing Python build dependencies (numpy, wheel, setuptools)"
uv pip install numpy wheel setuptools

# Validate build script exists
BUILD_SH="${ORT_SRC_DIR}/build.sh"
[[ -x "${BUILD_SH}" ]] || err "build.sh not found at ${BUILD_SH}"

info ">>> Native CPU build: ${NATIVE_CPU_CONFIG} (${JOBS} parallel jobs)"
info "Using Python: ${HOST_PYTHON}"
info "NumPy version: $(${HOST_PYTHON} -c 'import numpy; print(numpy.__version__)')"

# Prepare directories
mkdir -p "${NATIVE_CPU_OUTPUT_DIR}"/{lib,include,wheels}

BUILD_ARGS=(
  --build_dir "${NATIVE_CPU_BUILD_DIR}"
  --config "${NATIVE_CPU_CONFIG}"
  --build_shared_lib
  --parallel "${JOBS}"
  --compile_no_warning_as_error
  --skip_submodule_sync
  --skip_tests
  --allow_running_as_root
  --use_xnnpack
  --use_mimalloc
  --use_lock_free_queue
)

BUILD_ARGS+=(
  --cmake_extra_defines
  "CMAKE_POLICY_VERSION_MINIMUM=${CMAKE_POLICY_VERSION_MINIMUM}"
)

if [ "${ORT_ENABLE_LTO:-false}" = "true" ]; then
  BUILD_ARGS+=(
    --enable_lto
  )
fi

if [ "${ORT_ENABLE_WEBGPU:-false}" = "true" ]; then
  BUILD_ARGS+=(
    --use_webgpu
    --use_external_dawn
  )
fi

if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled; then
  info "Skipping ONNX Runtime wheel build in cross mode; target Python headers/wheels are not safely buildable in the amd64 host container"
  BUILD_ARGS+=(
    --cmake_extra_defines
    CMAKE_SYSTEM_NAME=Linux
    CMAKE_SYSTEM_PROCESSOR="${CROSS_TARGET_PROCESSOR}"
    CMAKE_C_COMPILER="${CC}"
    CMAKE_CXX_COMPILER="${CXX}"
    CMAKE_ASM_COMPILER="${CC}"
    CMAKE_SYSROOT=/
    CMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
    CMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
    CMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
    CMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
    onnxruntime_ENABLE_PYTHON=OFF
    onnxruntime_BUILD_UNIT_TESTS=OFF
    onnxruntime_GENERATE_TEST_REPORTS=OFF
  )
else
  BUILD_ARGS+=(--build_wheel)
fi

# Add lld linker for faster linking
if command -v ld.lld >/dev/null 2>&1 && [ "${USE_LLD:-true}" != "false" ]; then
  BUILD_ARGS+=(
    --cmake_extra_defines
    CMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld
    CMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld
    CMAKE_MODULE_LINKER_FLAGS=-fuse-ld=lld
  )
  info "Using lld linker for faster linking"
fi

# Add ccache for faster compilation
# Note: Only add if CMAKE_C_COMPILER_LAUNCHER is not already set by compiler-cache.sh
if command -v ccache >/dev/null 2>&1 && [ "${USE_CCACHE:-true}" != "false" ]; then
  if [ -z "${CMAKE_C_COMPILER_LAUNCHER:-}" ]; then
    BUILD_ARGS+=(
      --cmake_extra_defines
      CMAKE_C_COMPILER_LAUNCHER=ccache
      CMAKE_CXX_COMPILER_LAUNCHER=ccache
    )
    info "Using ccache for faster compilation (via cmake_extra_defines)"
  else
    info "ccache already configured via environment (CMAKE_C_COMPILER_LAUNCHER=${CMAKE_C_COMPILER_LAUNCHER})"
  fi
fi

# Execute build
if ! "${BUILD_SH}" "${BUILD_ARGS[@]}"; then
  if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled; then
    warn "ONNX Runtime build failed; rerunning single-threaded verbose build for diagnostics"
    cmake --build "${NATIVE_CPU_BUILD_DIR}/${NATIVE_CPU_CONFIG}" --config "${NATIVE_CPU_CONFIG}" --parallel 1 --verbose || true
  fi
  exit 1
fi

# Copy wheel files
info "Searching for wheel files..."
find "${NATIVE_CPU_BUILD_DIR}" -name "*.whl" -type f 2>/dev/null | while read -r whl; do
  info "Copying wheel: ${whl}"
  cp "${whl}" "${NATIVE_CPU_OUTPUT_DIR}/wheels/"
  ls -lh "${NATIVE_CPU_OUTPUT_DIR}/wheels/$(basename "${whl}")"
done || info "No wheels found in ${NATIVE_CPU_BUILD_DIR}"

# Additionally, try building a wheel from source if the ORT build did not produce one
if [ -z "$(ls -A "${NATIVE_CPU_OUTPUT_DIR}/wheels" 2>/dev/null || true)" ] && { ! command -v cross_build_enabled >/dev/null 2>&1 || ! cross_build_enabled; }; then
  info "No wheels found from ONNX Runtime build; attempting to build wheel via pip"
  if [ -f "${ORT_SRC_DIR}/pyproject.toml" ] || [ -f "${ORT_SRC_DIR}/setup.py" ]; then
    info "Building wheel from ORT python package"
    mkdir -p "${NATIVE_CPU_OUTPUT_DIR}/wheels"
    "${HOST_PYTHON}" -m pip wheel -w "${NATIVE_CPU_OUTPUT_DIR}/wheels" "${ORT_SRC_DIR}" || info "pip wheel failed for ORT source"
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
