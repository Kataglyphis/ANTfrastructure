#!/usr/bin/env bash
set -euo pipefail
# Build ONNX Runtime with the CUDA, TensorRT and cuDNN execution providers.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

source_build_acceleration_helpers

# NVIDIA defaults
init_nvidia_defaults() {
  NATIVE_GPU_OUTPUT_DIR="${NATIVE_GPU_OUTPUT_DIR:-/usr/local/lib/onnxruntime-gpu}"

  CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"

  TENSORRT_HOME="${TENSORRT_HOME:-/usr/local/tensorrt}"
  if [ ! -d "${TENSORRT_HOME}" ] || [ ! -f "${TENSORRT_HOME}/include/NvInfer.h" ]; then
    TRT_INC=$(find /usr/include /usr/local -name "NvInfer.h" -print -quit 2>/dev/null || true)
    if [ -n "$TRT_INC" ]; then
      # build.sh wants TENSORRT_HOME/{include,lib}, which the distro packages split, so link a merged tree.
      mkdir -p /tmp/tensorrt/include /tmp/tensorrt/lib
      ln -snf "$(dirname "$TRT_INC")"/* /tmp/tensorrt/include/
      ARCH="$(uname -m)"
      case "$ARCH" in
        x86_64) DEB_ARCH="x86_64-linux-gnu" ;;
        aarch64) DEB_ARCH="aarch64-linux-gnu" ;;
        *) DEB_ARCH="$ARCH" ;;
      esac
      if [ -d "/usr/lib/${DEB_ARCH}" ]; then
        ln -snf "/usr/lib/${DEB_ARCH}"/libnvinfer* /tmp/tensorrt/lib/ 2>/dev/null || true
      fi
      ln -snf /usr/lib/libnvinfer* /tmp/tensorrt/lib/ 2>/dev/null || true
      TENSORRT_HOME="/tmp/tensorrt"
    else
      for candidate in /usr /usr/local; do
        if [ -f "${candidate}/include/NvInfer.h" ]; then
          TENSORRT_HOME="${candidate}"
          break
        fi
      done
    fi
  fi

  # cuDNN: usually ships as part of CUDA or in /usr/lib/x86_64-linux-gnu
  CUDNN_HOME="${CUDNN_HOME:-${CUDA_HOME}}"

  NATIVE_GPU_BUILD_DIR="${NATIVE_GPU_BUILD_DIR:-${ORT_SRC_DIR}/build_native_gpu}"
}

parse_nvidia_args() {
  parse_common_args "$@"
  init_nvidia_defaults
}

parse_nvidia_args "$@"

# A CUDA job runs one cicc per nvcc thread; see docs/failure-modes.md § A CUDA compile is `Killed` though average memory looked fine
if [ -z "${JOBS:-}" ] && declare -F mem_capped_jobs >/dev/null 2>&1; then
  _cuda_peak_mb=$(( ${ONNX_NVCC_THREADS:-4} * ${CUDA_MB_PER_CICC:-3500} ))
  JOBS="$(mem_capped_jobs "${_cuda_peak_mb}")"
  # Floor of 2: one job takes hours, and the staggered peak rarely hits the cap.
  [ "${JOBS}" -ge 2 ] 2>/dev/null || JOBS=2
  export JOBS
  info "CUDA build: ${ONNX_NVCC_THREADS:-4} nvcc thread(s) x ${CUDA_MB_PER_CICC:-3500} MB => ${_cuda_peak_mb} MB/job, JOBS=${JOBS} (~$(( JOBS * ${ONNX_NVCC_THREADS:-4} )) concurrent cicc)"
fi
detect_jobs

# Toolchain checks
if [ ! -x "${CUDA_HOME}/bin/nvcc" ]; then
  err "nvcc not found at ${CUDA_HOME}/bin/nvcc. Ensure CUDA is installed and CUDA_HOME is correct."
fi
CUDA_VERSION_FULL="$("${CUDA_HOME}/bin/nvcc" --version | awk '/release/ {gsub(/,/,""); print $5; exit}')"
info "CUDA version: ${CUDA_VERSION_FULL}"

# TensorRT is required unless ENABLE_TENSORRT=false, which a CUDA+cuDNN image without it (Jetson) sets.
_ORT_USE_TENSORRT=1
if [ "${ENABLE_TENSORRT:-true}" = "false" ]; then
  _ORT_USE_TENSORRT=0
  info "ENABLE_TENSORRT=false — building the ONNX Runtime CUDA EP WITHOUT TensorRT"
elif [ ! -f "${TENSORRT_HOME}/include/NvInfer.h" ]; then
  err "TensorRT headers not found at ${TENSORRT_HOME}/include/NvInfer.h. \
Set TENSORRT_HOME to your TensorRT installation, or pass ENABLE_TENSORRT=false to \
build the CUDA EP without it."
fi
[ "${_ORT_USE_TENSORRT}" = "1" ] && info "TensorRT home: ${TENSORRT_HOME}"

CUDNN_H=""
for candidate in \
    "${CUDNN_HOME}/include/cudnn.h" \
    "${CUDNN_HOME}/include/cudnn_version.h" \
    /usr/include/cudnn.h \
    /usr/local/include/cudnn.h \
    /usr/include/x86_64-linux-gnu/cudnn.h \
    /usr/include/x86_64-linux-gnu/cudnn_version.h \
    /usr/include/aarch64-linux-gnu/cudnn.h \
    /usr/include/aarch64-linux-gnu/cudnn_version.h; do
  if [ -f "${candidate}" ]; then
    CUDNN_H="${candidate}"
    if [[ "${candidate}" == "/usr/include/"* ]]; then
      CUDNN_HOME="/usr"
    elif [[ "${candidate}" == "/usr/local/include/"* ]]; then
      CUDNN_HOME="/usr/local"
    fi
    break
  fi
done
if [ -z "${CUDNN_H}" ]; then
  err "cuDNN headers not found. Ensure cuDNN is installed and CUDNN_HOME is correct."
fi
info "cuDNN header: ${CUDNN_H}"

# Build dependencies
if [ "${SKIP_DEP_INSTALL:-false}" != "true" ]; then
    # The media stage runs as root in images that may not ship sudo.
    if command -v sudo >/dev/null 2>&1; then
        sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends libgcc-s1
    else
        apt-get update -qq && apt-get install -y --no-install-recommends libgcc-s1
    fi
fi

info "Using existing Python virtual environment (expected at /opt/python/.venv)"
setup_host_python_environment
HOST_PYTHON="${HOST_PYTHON_BIN}"
ensure_uv_python_packages "${HOST_PYTHON}" numpy wheel setuptools

BUILD_SH="${ORT_SRC_DIR}/build.sh"
[[ -x "${BUILD_SH}" ]] || err "build.sh not found at ${BUILD_SH}"

info ">>> Native GPU build (CUDA+TensorRT+cuDNN): ${NATIVE_CPU_CONFIG} (${JOBS} parallel jobs)"
info "Using Python: ${HOST_PYTHON}"
info "NumPy version: $(${HOST_PYTHON} -c 'import numpy; print(numpy.__version__)')"

ensure_onnx_output_tree "${NATIVE_GPU_OUTPUT_DIR}"

# ORT normalises every arch entry to sm_<cc>a-real itself, so the list passes through unchanged.
ONNX_CUDA_ARCHS="${CUDA_ARCHITECTURES:-86;87;89;120}"

BUILD_ARGS=()
append_onnx_native_base_build_args BUILD_ARGS "${NATIVE_GPU_BUILD_DIR}" "${NATIVE_CPU_CONFIG}" "${JOBS}"
BUILD_ARGS+=(
  --build_wheel
  --use_cuda
  --cuda_home          "${CUDA_HOME}"
  --cudnn_home         "${CUDNN_HOME}"
  --cmake_extra_defines "CMAKE_CUDA_ARCHITECTURES=${ONNX_CUDA_ARCHS}"
)
# --use_full_protobuf travels WITH the TensorRT EP: it is the TRT EP that needs it.
if [ "${_ORT_USE_TENSORRT}" = "1" ]; then
  BUILD_ARGS+=(
    --use_tensorrt
    --use_full_protobuf
    --tensorrt_home    "${TENSORRT_HOME}"
  )
fi
BUILD_ARGS+=(--use_xnnpack)

# ORT defaults telemetry on, and its vendored sqlite fails GCC 16's -Werror, which --compile_no_warning_as_error cannot reach.
BUILD_ARGS+=(--no_telemetry)

# The shared helper carries the -Wno-invalid-constexpr flag Dawn needs under GCC 16.
append_onnx_optional_lto_webgpu_args BUILD_ARGS

# ccache cannot wrap nvcc, so CUDA takes only an sccache-class launcher.
if [ "${ENABLE_SCCACHE_CUDA:-0}" = "1" ]; then
  compiler_cache_launcher_env 2>/dev/null || true
  _gpu_launcher="$(compiler_cache_launcher 2>/dev/null || true)"
  case "${_gpu_launcher}" in
    *sccache*)
      info "sccache: wrapping nvcc via CMAKE_CUDA_COMPILER_LAUNCHER (${_gpu_launcher})"
      BUILD_ARGS+=(--cmake_extra_defines "CMAKE_CUDA_COMPILER_LAUNCHER=${_gpu_launcher}")
      ;;
    *)
      warn "sccache unavailable for CUDA caching — building uncached"
      ;;
  esac
fi

append_onnx_lld_build_args BUILD_ARGS
append_onnx_ccache_build_args BUILD_ARGS

"${BUILD_SH}" "${BUILD_ARGS[@]}"

collect_wheels_from_tree "${NATIVE_GPU_BUILD_DIR}" "${NATIVE_GPU_OUTPUT_DIR}" "GPU wheel"
copy_onnx_headers_to_output "${NATIVE_GPU_OUTPUT_DIR}" "${ORT_SRC_DIR}" "${NATIVE_GPU_BUILD_DIR}"
finalize_onnx_native_output "${NATIVE_GPU_BUILD_DIR}" "${NATIVE_CPU_CONFIG}" "${NATIVE_GPU_OUTPUT_DIR}" "${ORT_SRC_DIR}"

report_onnx_build_output "GPU build complete" "${NATIVE_GPU_OUTPUT_DIR}"

# Last, so every GIL output above is final before the tree is reconfigured.
onnx_build_free_threaded_wheel "${NATIVE_GPU_BUILD_DIR}" "${NATIVE_CPU_CONFIG}" "${NATIVE_GPU_OUTPUT_DIR}" BUILD_ARGS
