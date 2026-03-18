#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

parse_common_args "$@"

info "Running ONNX Runtime build pipeline (wrapper)"

bash "${SCRIPT_DIR}/10-deps.sh" "$@"
bash "${SCRIPT_DIR}/20-fetch.sh" "$@"
bash "${SCRIPT_DIR}/30-build-native.sh" "$@"

if [[ "${BUILD_GENAI}" == "true" ]]; then
  bash "${SCRIPT_DIR}/60-build-genai.sh" "$@"
else
  info "Skipping GenAI build (BUILD_GENAI=${BUILD_GENAI})"
fi

if is_amd64_arch; then
  bash "${SCRIPT_DIR}/40-build-wasm.sh" "$@"
  bash "${SCRIPT_DIR}/50-build-js.sh" "$@"
else
  info "Skipping all web builds (WASM/JS) on non-amd64 architecture (arch=$(detect_target_arch))"
fi

info "Complete build finished. Artifacts:"
info "  - Native CPU: ${NATIVE_CPU_OUTPUT_DIR}"
if [[ "${BUILD_GENAI}" == "true" ]]; then
  info "  - GenAI: ${GENAI_OUTPUT_DIR}"
fi
info "  - Web: ${WASM_OUTPUT_DIR}"
