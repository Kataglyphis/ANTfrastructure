#!/usr/bin/env bash
# ==============================================================================
# 30-build-native-amd.sh
# Build ONNX Runtime with ROCm Execution Provider.
#
# Requires:
#   - ROCm toolkit in /opt/rocm
#
# Outputs:
#   - Shared libs + headers → ${NATIVE_GPU_OUTPUT_DIR}
#   - Wheel files            → ${NATIVE_GPU_OUTPUT_DIR}/wheels
#
# Build Acceleration:
#   USE_CCACHE=true     Enable ccache for faster rebuilds (default: true)
#   USE_LLD=true        Use lld linker for faster linking (default: true)
# ==============================================================================
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

# --------------------------------------------------------------------------
# Additional defaults specific to the AMD/GPU build
# --------------------------------------------------------------------------
init_amd_defaults() {
  # Where to install GPU-accelerated ORT
  NATIVE_GPU_OUTPUT_DIR="${NATIVE_GPU_OUTPUT_DIR:-/usr/local/lib/onnxruntime-gpu}"

  # ROCm path
  ROCM_HOME="${ROCM_HOME:-/opt/rocm}"
  ROCM_VERSION="${ROCM_VERSION:-6.1}"

  # Build directory for GPU variant (separate from CPU build)
  NATIVE_GPU_BUILD_DIR="${NATIVE_GPU_BUILD_DIR:-${ORT_SRC_DIR}/build_native_gpu}"
}

parse_amd_args() {
  parse_common_args "$@"
  init_amd_defaults
}

parse_amd_args "$@"
detect_jobs

# --------------------------------------------------------------------------
# Sanity-check: ROCm must be present
# --------------------------------------------------------------------------
if [ ! -d "${ROCM_HOME}" ]; then
  err "ROCm not found at ${ROCM_HOME}. Ensure ROCm is installed and ROCM_HOME is correct."
fi
info "ROCm home: ${ROCM_HOME} (version: ${ROCM_VERSION})"

# --------------------------------------------------------------------------
# Install Python build dependencies
# --------------------------------------------------------------------------
sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends libgcc-s1

info "Using existing Python virtual environment (expected at /opt/python/.venv)"
uv pip install numpy wheel setuptools

# --------------------------------------------------------------------------
# Validate build script
# --------------------------------------------------------------------------
BUILD_SH="${ORT_SRC_DIR}/build.sh"
[[ -x "${BUILD_SH}" ]] || err "build.sh not found at ${BUILD_SH}"

info ">>> Native GPU build (ROCm): ${NATIVE_CPU_CONFIG} (${JOBS} parallel jobs)"
info "Using Python: $(which python3)"
info "NumPy version: $(python3 -c 'import numpy; print(numpy.__version__)')"

# --------------------------------------------------------------------------
# Prepare output directories
# --------------------------------------------------------------------------
mkdir -p "${NATIVE_GPU_OUTPUT_DIR}"/{lib,include,wheels}

# --------------------------------------------------------------------------
# Build ONNX Runtime with GPU EPs
# --------------------------------------------------------------------------
# Key flags:
#   --use_migraphx        – enable the MIGraphX Execution Provider
#   --migraphx_home       – path to MIGraphX (usually within ROCm toolkit)

BUILD_ARGS=(
  --build_dir          "${NATIVE_GPU_BUILD_DIR}"
  --config             "${NATIVE_CPU_CONFIG}"
  --build_shared_lib
  --parallel           "${JOBS}"
  --build_wheel
  --compile_no_warning_as_error
  --skip_submodule_sync
  --skip_tests
  --allow_running_as_root
  --use_migraphx
  --migraphx_home      "${ROCM_HOME}"
  --use_xnnpack
  --enable_lto
  --use_mimalloc
  --use_lock_free_queue

  --use_webgpu
  --use_external_dawn
)

CMAKE_EXTRA_DEFINES=(
  "migraphx_DIR=${ROCM_HOME}/lib/cmake/migraphx"
)

# Add lld linker for faster linking
if command -v ld.lld >/dev/null 2>&1 && [ "${USE_LLD:-true}" != "false" ]; then
  CMAKE_EXTRA_DEFINES+=(
    "CMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld"
    "CMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld"
    "CMAKE_MODULE_LINKER_FLAGS=-fuse-ld=lld"
  )
  info "Using lld linker for faster linking"
fi

# Add ccache for faster compilation
if command -v ccache >/dev/null 2>&1 && [ "${USE_CCACHE:-true}" != "false" ]; then
  CMAKE_EXTRA_DEFINES+=(
    "CMAKE_C_COMPILER_LAUNCHER=ccache"
    "CMAKE_CXX_COMPILER_LAUNCHER=ccache"
  )
  info "Using ccache for faster compilation"
fi

if [ ${#CMAKE_EXTRA_DEFINES[@]} -gt 0 ]; then
  BUILD_ARGS+=(
    --cmake_extra_defines "${CMAKE_EXTRA_DEFINES[@]}"
  )
fi

"${BUILD_SH}" "${BUILD_ARGS[@]}"

# --------------------------------------------------------------------------
# Collect artifacts
# --------------------------------------------------------------------------
info "Searching for wheel files..."
find "${NATIVE_GPU_BUILD_DIR}" -name "*.whl" -type f 2>/dev/null | while read -r whl; do
  info "Copying wheel: ${whl}"
  cp "${whl}" "${NATIVE_GPU_OUTPUT_DIR}/wheels/"
  ls -lh "${NATIVE_GPU_OUTPUT_DIR}/wheels/$(basename "${whl}")"
done || info "No wheels found in ${NATIVE_GPU_BUILD_DIR}"

# Copy headers
cp -a "${ORT_SRC_DIR}/include" "${NATIVE_GPU_OUTPUT_DIR}/" 2>/dev/null || \
  warn "Include directory not found at ${ORT_SRC_DIR}/include"

# Flatten headers for GenAI - it expects headers at include/ root
for search_dir in "${ORT_SRC_DIR}" "${NATIVE_GPU_BUILD_DIR}"; do
  if [[ ! -d "${search_dir}/include" ]]; then
    continue
  fi
  find "${search_dir}/include" -name "onnxruntime*.h" -type f 2>/dev/null | while read -r hdr; do
    cp "${hdr}" "${NATIVE_GPU_OUTPUT_DIR}/include/" 2>/dev/null || true
  done
done

# Copy libraries
mkdir -p "${NATIVE_GPU_OUTPUT_DIR}/lib"
find "${NATIVE_GPU_BUILD_DIR}/${NATIVE_CPU_CONFIG}" -maxdepth 1 -type f \
  \( -name "libonnxruntime*.so*" -o -name "libonnxruntime_providers_*.so*" \) \
  -exec cp -t "${NATIVE_GPU_OUTPUT_DIR}/lib/" {} + 2>/dev/null || true

# Create unversioned symlink for libonnxruntime.so (required by GenAI CMake)
onnx_lib="$(find "${NATIVE_GPU_OUTPUT_DIR}/lib" -maxdepth 1 -name 'libonnxruntime.so.*' -type f | head -1)"
if [[ -n "${onnx_lib}" ]] && [[ ! -e "${NATIVE_GPU_OUTPUT_DIR}/lib/libonnxruntime.so" ]]; then
  ln -sf "$(basename "${onnx_lib}")" "${NATIVE_GPU_OUTPUT_DIR}/lib/libonnxruntime.so"
  info "Created symlink: libonnxruntime.so -> $(basename "${onnx_lib}")"
fi

# Symlink into /usr/local/lib for discovery
find "${NATIVE_GPU_OUTPUT_DIR}/lib" -type f -name "lib*.so*" -print0 2>/dev/null | \
  xargs -0 -r ln -sf -t /usr/local/lib/ 2>/dev/null || true

ldconfig 2>/dev/null || true

info "GPU build complete. Artifacts in ${NATIVE_GPU_OUTPUT_DIR}"
info "Wheels in ${NATIVE_GPU_OUTPUT_DIR}/wheels"
ls -lh "${NATIVE_GPU_OUTPUT_DIR}/wheels"/*.whl 2>/dev/null || true
ls -lh "${NATIVE_GPU_OUTPUT_DIR}/lib"/*.so* 2>/dev/null | head -20 || true
