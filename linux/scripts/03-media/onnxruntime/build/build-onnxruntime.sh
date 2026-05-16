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
    if is_amd64_arch; then
      bash "${SCRIPT_DIR}/40-build-wasm.sh" "${FORWARDED_ARGS[@]}"
      bash "${SCRIPT_DIR}/50-build-js.sh" "${FORWARDED_ARGS[@]}"
    else
      info "Skipping all web builds (WASM/JS) on non-amd64 architecture (arch=$(detect_target_arch))"
    fi
    bash "${SCRIPT_DIR}/../runtime/31-generate-pkgconfig-native.sh" "${FORWARDED_ARGS[@]}"
    bash "${SCRIPT_DIR}/70-build-litert.sh" "${FORWARDED_ARGS[@]}" || info "LiteRT build script failed or was skipped"
    info "Complete build finished. Artifacts:"
    info "  - Native CPU: ${NATIVE_CPU_OUTPUT_DIR}"
    if [[ "${BUILD_GENAI}" == "true" ]]; then
      info "  - GenAI: ${GENAI_OUTPUT_DIR}"
    fi
    info "  - Web: ${WASM_OUTPUT_DIR}"
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
    if is_amd64_arch; then
      bash "${SCRIPT_DIR}/40-build-wasm.sh" "${FORWARDED_ARGS[@]}"
    else
      info "Skipping WASM build on non-amd64 architecture (arch=$(detect_target_arch))"
    fi
    ;;
  js)
    if is_amd64_arch; then
      bash "${SCRIPT_DIR}/50-build-js.sh" "${FORWARDED_ARGS[@]}"
    else
      info "Skipping JS build on non-amd64 architecture (arch=$(detect_target_arch))"
    fi
    ;;
  pkgconfig)
    bash "${SCRIPT_DIR}/../runtime/31-generate-pkgconfig-native.sh" "${FORWARDED_ARGS[@]}"
    ;;
  litert-helper)
    bash "${SCRIPT_DIR}/70-build-litert.sh" "${FORWARDED_ARGS[@]}"
    ;;
  *)
    err "Unknown build step: ${STEP}"
    ;;
esac
