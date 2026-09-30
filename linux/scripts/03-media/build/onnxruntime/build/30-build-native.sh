#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

source_build_acceleration_helpers

parse_common_args "$@"
detect_jobs

[[ "${BUILD_NATIVE_CPU}" != "true" ]] && {
  info "Skipping native CPU build"
  exit 0
}

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

: "${ORT_PYTHON_VERSION:=$(host_python_major_minor)}"
setup_host_python_environment
HOST_PYTHON="${HOST_PYTHON_BIN}"
info "Using existing Python virtual environment (expected at /opt/python/.venv)"

info "Installing Python build dependencies (numpy, wheel, setuptools)"
ensure_uv_python_packages "${HOST_PYTHON}" numpy wheel setuptools

BUILD_SH="${ORT_SRC_DIR}/build.sh"
[[ -x "${BUILD_SH}" ]] || err "build.sh not found at ${BUILD_SH}"

info ">>> Native CPU build: ${NATIVE_CPU_CONFIG} (${JOBS} parallel jobs)"
info "Using Python: ${HOST_PYTHON}"
info "NumPy version: $(${HOST_PYTHON} -c 'import numpy; print(numpy.__version__)')"

ensure_onnx_output_tree "${NATIVE_CPU_OUTPUT_DIR}"

BUILD_ARGS=()
append_onnx_native_base_build_args BUILD_ARGS "${NATIVE_CPU_BUILD_DIR}" "${NATIVE_CPU_CONFIG}" "${JOBS}"
BUILD_ARGS+=(--use_xnnpack)
# ORT defaults telemetry on, and its vendored sqlite fails GCC 16's -Werror, which --compile_no_warning_as_error cannot reach.
BUILD_ARGS+=(--no_telemetry)

BUILD_ARGS+=(
  --cmake_extra_defines
  "CMAKE_POLICY_VERSION_MINIMUM=${CMAKE_POLICY_VERSION_MINIMUM}"
)

append_onnx_optional_lto_webgpu_args BUILD_ARGS

# oneDNN's kernels are x86-tuned, so the DNNL EP is built on x86_64 only.
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

# No Arm NN EP: ORT removed it and build.py rejects --use_armnn; Arm NN ships for direct use only.

# The QNN EP is arm64-only and opt-in by staging an SDK zip; see linux/qnn-sdk/README.md.
_qnn_home="$(resolve_qnn_sdk)"
if [ -n "$_qnn_home" ]; then
  info "QNN EP ON (SDK root ${_qnn_home})"
  # ORT's CMake defaults QNN_ARCH_ABI to aarch64-android, which is not the Linux SDK's lib dir.
  BUILD_ARGS+=(
    --cmake_extra_defines
    "onnxruntime_USE_QNN=ON"
    "onnxruntime_QNN_HOME=${_qnn_home}"
    "QNN_ARCH_ABI=aarch64-oe-linux-gcc11.2"
  )
else
  info "QNN EP off (no SDK zip staged — opt-in, see linux/qnn-sdk/README.md)"
fi

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

# See docs/failure-modes.md § A half-fetched dependency that every retry inherits
_ort_drop_partial_deps() {
  local d dep="${NATIVE_CPU_BUILD_DIR}/${NATIVE_CPU_CONFIG}/_deps"
  [ -d "${dep}" ] || return 0
  for d in "${dep}"/*-src/third_party/*/src "${dep}"/*-src/third_party/*/*/src; do
    [ -d "${d}" ] || continue
    [ -e "${d}/CMakeLists.txt" ] && continue
    warn "ONNX Runtime: dropping half-fetched dependency ${d}"
    rm -rf "${d:?}"
  done
}

_ort_build_attempt() {
  _ort_drop_partial_deps
  "${BUILD_SH}" "${BUILD_ARGS[@]}"
}

# Execute build (with retry for transient network errors like GitHub download failures)
if ! retry 3 10 "ONNX Runtime CPU build" _ort_build_attempt; then
  if cross_build_is_active; then
    warn "ONNX Runtime build failed; rerunning single-threaded verbose build for diagnostics"
    cmake --build "${NATIVE_CPU_BUILD_DIR}/${NATIVE_CPU_CONFIG}" --config "${NATIVE_CPU_CONFIG}" --parallel 1 --verbose || true
  fi
  exit 1
fi

collect_wheels_from_tree "${NATIVE_CPU_BUILD_DIR}" "${NATIVE_CPU_OUTPUT_DIR}" "ONNX Runtime wheel"

if [ -z "$(ls -A "${NATIVE_CPU_OUTPUT_DIR}/wheels" 2>/dev/null || true)" ] && { ! cross_build_is_active; }; then
  maybe_build_source_wheel "${ORT_SRC_DIR}" "${NATIVE_CPU_OUTPUT_DIR}" "${HOST_PYTHON}" "ONNX Runtime"
fi

copy_onnx_headers_to_output "${NATIVE_CPU_OUTPUT_DIR}" "${ORT_SRC_DIR}" "${NATIVE_CPU_BUILD_DIR}"
info "Listing copied headers:"
ls -la "${NATIVE_CPU_OUTPUT_DIR}/include/"*.h 2>/dev/null || warn "No .h files found in include directory"

finalize_onnx_native_output "${NATIVE_CPU_BUILD_DIR}" "${NATIVE_CPU_CONFIG}" "${NATIVE_CPU_OUTPUT_DIR}" "${ORT_SRC_DIR}"

if [ -n "$_qnn_home" ]; then
  stage_qnn_runtime "$_qnn_home" "${NATIVE_CPU_OUTPUT_DIR}" 'libonnxruntime_providers_qnn.so*'
fi

# ${STRIP} is the target's strip on cross builds, since the host strip skips foreign ELFs.
if [ "${MEDIA_STRIP:-1}" = "1" ]; then
  find "${NATIVE_CPU_OUTPUT_DIR}/lib" -maxdepth 2 -type f \
    \( -name '*.so' -o -name '*.so.*' \) \
    -exec "${STRIP:-strip}" --strip-all {} + 2>/dev/null || true
fi

report_onnx_build_output "Build complete" "${NATIVE_CPU_OUTPUT_DIR}"

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
