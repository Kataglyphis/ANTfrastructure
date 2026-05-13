#!/usr/bin/env bash
# ==============================================================================
# 30-build-native-amd.sh
# Build ONNX Runtime with the ROCm execution provider.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

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

ROCM_HOME="${ROCM_HOME:-/opt/rocm}"
ROCM_VERSION="${ROCM_VERSION:-6.1}"
NATIVE_GPU_OUTPUT_DIR="${NATIVE_GPU_OUTPUT_DIR:-/usr/local/lib/onnxruntime-gpu}"
NATIVE_GPU_BUILD_DIR="${NATIVE_GPU_BUILD_DIR:-${ORT_SRC_DIR}/build_native_gpu_rocm}"

if [ ! -d "${ROCM_HOME}" ]; then
  err "ROCm home not found at ${ROCM_HOME}. Install the AMD toolchain layer first."
fi

if command -v setup_linux_cross_env >/dev/null 2>&1; then
  setup_linux_cross_env
fi

sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends libgcc-s1

: "${ORT_PYTHON_VERSION:=$(host_python_major_minor)}"
HOST_PYTHON="$(host_python_bin)"
export PYTHON_EXECUTABLE="${HOST_PYTHON}" \
       Python_EXECUTABLE="${HOST_PYTHON}" \
       Python3_EXECUTABLE="${HOST_PYTHON}"

info "Using existing Python virtual environment (expected at /opt/python/.venv)"
uv pip install numpy wheel setuptools

BUILD_SH="${ORT_SRC_DIR}/build.sh"
[[ -x "${BUILD_SH}" ]] || err "build.sh not found at ${BUILD_SH}"

if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled; then
  warn "Skipping ONNX Runtime ROCm wheel build in cross mode; target wheel repair/validation is not supported here"
fi

info ">>> Native AMD GPU build (ROCm): ${NATIVE_CPU_CONFIG} (${JOBS} parallel jobs)"
info "Using Python: ${HOST_PYTHON}"
info "NumPy version: $(${HOST_PYTHON} -c 'import numpy; print(numpy.__version__)')"

mkdir -p "${NATIVE_GPU_OUTPUT_DIR}"/{lib,include,wheels}

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

if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled; then
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

if command -v ld.lld >/dev/null 2>&1 && [ "${USE_LLD:-true}" != "false" ]; then
  BUILD_ARGS+=(
    --cmake_extra_defines
    CMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld
    CMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld
    CMAKE_MODULE_LINKER_FLAGS=-fuse-ld=lld
  )
  info "Using lld linker for faster linking"
fi

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

export PATH="${ROCM_HOME}/bin:${PATH}"
export LD_LIBRARY_PATH="${ROCM_HOME}/lib:${ROCM_HOME}/lib64:${LD_LIBRARY_PATH:-}"

if ! "${BUILD_SH}" "${BUILD_ARGS[@]}"; then
  if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled; then
    warn "ONNX Runtime ROCm build failed; rerunning single-threaded verbose build for diagnostics"
    cmake --build "${NATIVE_GPU_BUILD_DIR}/${NATIVE_CPU_CONFIG}" --config "${NATIVE_CPU_CONFIG}" --parallel 1 --verbose || true
  fi
  exit 1
fi

info "Searching for ROCm wheel files..."
find "${NATIVE_GPU_BUILD_DIR}" -name "*.whl" -type f 2>/dev/null | while read -r whl; do
  info "Copying wheel: ${whl}"
  cp "${whl}" "${NATIVE_GPU_OUTPUT_DIR}/wheels/"
  ls -lh "${NATIVE_GPU_OUTPUT_DIR}/wheels/$(basename "${whl}")"
done || info "No wheels found in ${NATIVE_GPU_BUILD_DIR}"

if [ -z "$(ls -A "${NATIVE_GPU_OUTPUT_DIR}/wheels" 2>/dev/null || true)" ] && { ! command -v cross_build_enabled >/dev/null 2>&1 || ! cross_build_enabled; }; then
  info "No ROCm wheels found from ONNX Runtime build; attempting to build wheel via pip"
  if [ -f "${ORT_SRC_DIR}/pyproject.toml" ] || [ -f "${ORT_SRC_DIR}/setup.py" ]; then
    "${HOST_PYTHON}" -m pip wheel -w "${NATIVE_GPU_OUTPUT_DIR}/wheels" "${ORT_SRC_DIR}" || info "pip wheel failed for ORT source"
    info "Wheels after pip wheel:"
    ls -lh "${NATIVE_GPU_OUTPUT_DIR}/wheels"/*.whl 2>/dev/null || true
  fi
fi

mkdir -p "${NATIVE_GPU_OUTPUT_DIR}/include"
if [[ -d "${ORT_SRC_DIR}/include" ]]; then
  cp -a "${ORT_SRC_DIR}/include/." "${NATIVE_GPU_OUTPUT_DIR}/include/" 2>/dev/null || true
  info "Copied headers from ${ORT_SRC_DIR}/include"
fi

if [[ -d "${NATIVE_GPU_BUILD_DIR}/include" ]]; then
  cp -a "${NATIVE_GPU_BUILD_DIR}/include/." "${NATIVE_GPU_OUTPUT_DIR}/include/" 2>/dev/null || true
  info "Copied generated headers from ${NATIVE_GPU_BUILD_DIR}/include"
fi

for search_dir in "${ORT_SRC_DIR}" "${NATIVE_GPU_BUILD_DIR}"; do
  if [[ ! -d "${search_dir}/include" ]]; then
    continue
  fi
  find "${search_dir}/include" -name "onnxruntime*.h" -type f 2>/dev/null | while read -r hdr; do
    cp "${hdr}" "${NATIVE_GPU_OUTPUT_DIR}/include/" 2>/dev/null || true
  done
done

mkdir -p "${NATIVE_GPU_OUTPUT_DIR}/lib"
find "${NATIVE_GPU_BUILD_DIR}/${NATIVE_CPU_CONFIG}" -maxdepth 1 -type f \
  \( -name "libonnxruntime*.so*" -o -name "libonnxruntime_providers_*.so*" \) \
  -exec cp -t "${NATIVE_GPU_OUTPUT_DIR}/lib/" {} + 2>/dev/null || true

onnx_lib="$(find "${NATIVE_GPU_OUTPUT_DIR}/lib" -maxdepth 1 -name 'libonnxruntime.so.*' -type f | head -1)"
if [[ -n "${onnx_lib}" ]] && [[ ! -e "${NATIVE_GPU_OUTPUT_DIR}/lib/libonnxruntime.so" ]]; then
  ln -sf "$(basename "${onnx_lib}")" "${NATIVE_GPU_OUTPUT_DIR}/lib/libonnxruntime.so"
  info "Created symlink: libonnxruntime.so -> $(basename "${onnx_lib}")"
fi

find "${NATIVE_GPU_OUTPUT_DIR}/lib" -type f -name "lib*.so*" -print0 2>/dev/null | \
  xargs -0 -r ln -sf -t /usr/local/lib/ 2>/dev/null || true

ldconfig 2>/dev/null || true

info "AMD GPU build complete. Artifacts in ${NATIVE_GPU_OUTPUT_DIR}"
info "Wheels in ${NATIVE_GPU_OUTPUT_DIR}/wheels"
ls -lh "${NATIVE_GPU_OUTPUT_DIR}/wheels"/*.whl 2>/dev/null || true
find "${NATIVE_GPU_OUTPUT_DIR}/lib" -maxdepth 1 -type f -name "*.so*" -printf '%f\n' 2>/dev/null | sed -n '1,20p' || true
