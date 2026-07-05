#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

STEP="all"
FORWARDED_ARGS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --step)
      [ "$#" -ge 2 ] || err "--step requires a value"
      STEP="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 --step <step> [FORWARDED_ARGS...]"
      echo ""
      echo "Build ONNX Runtime (and GenAI/LiteRT steps) from source."
      echo ""
      echo "Steps:"
      echo "  deps        Install build dependencies"
      echo "  fetch       Fetch ONNX Runtime source"
      echo "  cpu         Build native CPU EP"
      echo "  gpu         Build GPU EP (NVIDIA CUDA or AMD MIGraphX)"
      echo "  genai       Build ONNX Runtime GenAI"
      echo "  wasm        Build WebAssembly target"
      echo "  js          Build JS bindings"
      echo "  pkgconfig   Generate pkg-config files"
      echo "  all         Run every step (default)"
      echo ""
      echo "Environment:"
      echo "  ENABLE_NVIDIA=true   Enable CUDA/TensorRT EPs"
      echo "  ENABLE_AMD=true      Enable MIGraphX EP"
      echo "  BUILD_GENAI=false    Skip GenAI build"
      exit 0
      ;;
    *)
      FORWARDED_ARGS+=("$1")
      shift
      ;;
  esac
done

parse_common_args "${FORWARDED_ARGS[@]}"

run_gpu_build_step() {
  if [ "${ENABLE_NVIDIA:-false}" = "true" ]; then
    bash "${SCRIPT_DIR}/30-build-native-nvidia.sh" "${FORWARDED_ARGS[@]}"
  elif [ "${ENABLE_AMD:-false}" = "true" ]; then
    bash "${SCRIPT_DIR}/30-build-native-amd.sh" "${FORWARDED_ARGS[@]}"
  else
    info "Skipping GPU build (ENABLE_NVIDIA=${ENABLE_NVIDIA:-false}, ENABLE_AMD=${ENABLE_AMD:-false})"
  fi
}

ensure_onnx_gpu_placeholder_output_dir

# Run a web (WASM/JS) build step only on amd64; emscripten/web builds are not
# produced for the cross targets. DRYs the identical is_amd64_arch gate.
run_web_build_step() {
  local script="$1" label="$2"
  if is_amd64_arch; then
    bash "${SCRIPT_DIR}/${script}" "${FORWARDED_ARGS[@]}"
  else
    info "Skipping ${label} on non-amd64 architecture (arch=$(detect_target_arch))"
  fi
}

case "${STEP}" in
  all)
    info "Running ONNX Runtime build pipeline"
    bash "${SCRIPT_DIR}/10-deps.sh" "${FORWARDED_ARGS[@]}"
    bash "${SCRIPT_DIR}/20-fetch.sh" "${FORWARDED_ARGS[@]}"
    bash "${SCRIPT_DIR}/30-build-native.sh" "${FORWARDED_ARGS[@]}"
    run_gpu_build_step
    if [[ "${BUILD_GENAI}" == "true" ]]; then
      bash "${SCRIPT_DIR}/60-build-genai.sh" "${FORWARDED_ARGS[@]}"
    else
      info "Skipping GenAI build (BUILD_GENAI=${BUILD_GENAI})"
    fi
    run_web_build_step 40-build-wasm.sh "WASM build"
    run_web_build_step 50-build-js.sh "JS build"
    bash "${SCRIPT_DIR}/../runtime/31-generate-pkgconfig-native.sh" "${FORWARDED_ARGS[@]}"
    info "Complete build finished. Artifacts:"
    info "  - Native CPU: ${NATIVE_CPU_OUTPUT_DIR}"
    if [[ "${BUILD_GENAI}" == "true" ]]; then
      info "  - GenAI: ${GENAI_OUTPUT_DIR}"
    fi
    info "  - Web: ${WASM_OUTPUT_DIR}"
    info "  - LiteRT: built separately via the dedicated 03-media litert stage (Dockerfile.media); use --step litert-helper to build it here"
    ;;
  deps)
    bash "${SCRIPT_DIR}/10-deps.sh" "${FORWARDED_ARGS[@]}"
    ;;
  fetch)
    bash "${SCRIPT_DIR}/20-fetch.sh" "${FORWARDED_ARGS[@]}"
    ;;
  cpu|native)
    bash "${SCRIPT_DIR}/30-build-native.sh" "${FORWARDED_ARGS[@]}"
    ;;
  gpu)
    run_gpu_build_step
    ;;
  genai)
    bash "${SCRIPT_DIR}/60-build-genai.sh" "${FORWARDED_ARGS[@]}"
    ;;
  wasm)
    run_web_build_step 40-build-wasm.sh "WASM build"
    ;;
  js)
    run_web_build_step 50-build-js.sh "JS build"
    ;;
  pkgconfig)
    bash "${SCRIPT_DIR}/../runtime/31-generate-pkgconfig-native.sh" "${FORWARDED_ARGS[@]}"
    ;;
  litert-helper)
    bash "${SCRIPT_DIR}/70-build-litert.sh" "${FORWARDED_ARGS[@]}"
    ;;
  smoke)
    info "Running ONNX Runtime post-build smoke tests..."
    HOST_PYTHON="$(host_python_bin 2>/dev/null || echo python3)"
    "${HOST_PYTHON}" -c "import onnxruntime; print('onnxruntime', onnxruntime.__version__)" || warn "onnxruntime import failed"
    if [ -d "${NATIVE_CPU_OUTPUT_DIR}/include" ]; then
      if [ -f "${NATIVE_CPU_OUTPUT_DIR}/include/onnxruntime/core/session/onnxruntime_c_api.h" ]; then
        info "ONNX Runtime C API headers OK"
      else
        warn "ONNX Runtime C API headers missing"
      fi
    fi
    if [ -f "${NATIVE_CPU_OUTPUT_DIR}/runtime/lib/pkgconfig/libonnxruntime.pc" ]; then
      info "ONNX Runtime pkg-config OK"
    else
      warn "ONNX Runtime pkg-config missing"
    fi
    if [ "${BUILD_GENAI}" = "true" ]; then
      "${HOST_PYTHON}" -c "import onnxruntime_genai" 2>/dev/null && info "onnxruntime_genai OK" || warn "onnxruntime_genai import failed"
    fi
    info "ONNX Runtime smoke tests complete"
    ;;
  *)
    err "Unknown build step: ${STEP}"
    ;;
esac
