#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

parse_common_args "$@"
detect_jobs

if ! is_amd64_arch; then
  info "Skipping WASM/web build on non-amd64 architecture (arch=$(detect_target_arch))"
  exit 0
fi

cd "${ORT_SRC_DIR}"

# If emsdk exists in repo, ensure env is set for this shell
EMSDK_DIR="${ORT_SRC_DIR}/cmake/external/emsdk"
if [ -d "${EMSDK_DIR}" ] && [ -f "${EMSDK_DIR}/emsdk_env.sh" ]; then
  # shellcheck disable=SC1091
  source "${EMSDK_DIR}/emsdk_env.sh" || true
fi

BUILD_SH="${ORT_SRC_DIR}/build.sh"
[ -x "${BUILD_SH}" ] || err "build.sh not found or not executable at ${BUILD_SH}"

COMMON_ARGS=(
  "--build_dir" "${BUILD_DIR}"
  "--config" "${WASM_CONFIG}"
  "--build_wasm"
  "--parallel" "${JOBS}"
  "--cmake_extra_defines" "CMAKE_POLICY_VERSION_MINIMUM=${CMAKE_POLICY_VERSION_MINIMUM}"
  "--skip_tests"
  "--disable_wasm_exception_catching"
  "--disable_rtti"
  "--allow_running_as_root"
)

mkdir -p "${WASM_OUTPUT_DIR}"
rm -rf "${BUILD_DIR}" || true

if [ "${ENABLE_ASYNCIFY}" = "true" ]; then
  info "Enabling Asyncify via EMCC flags (ASYNCIFY_STACK_SIZE=${ASYNCIFY_STACK_SIZE})"
  export EMCC_CFLAGS="-s ASYNCIFY=1 -s ASYNCIFY_STACK_SIZE=${ASYNCIFY_STACK_SIZE}"
  export EMCC_LINKER_FLAGS="${EMCC_CFLAGS}"
fi

info ">>> Pass 1: SIMD + Threads"
rm -rf "${BUILD_DIR}"
"${BUILD_SH}" "${COMMON_ARGS[@]}" --enable_wasm_simd --enable_wasm_threads
find "${BUILD_DIR}/${WASM_CONFIG}" -type f -name "ort-wasm-simd-threaded.*" -exec cp -v '{}' "${WASM_OUTPUT_DIR}/" ';' || true

info ">>> Pass 2: JSEP (WebGPU/WebNN)"
rm -rf "${BUILD_DIR}"
"${BUILD_SH}" "${COMMON_ARGS[@]}" --enable_wasm_simd --enable_wasm_threads --use_jsep --use_webnn
find "${BUILD_DIR}/${WASM_CONFIG}" -type f \( -name "ort-wasm-simd-threaded.jsep.*" -o -name "ort-wasm-simd-threaded.webnn.*" \) -exec cp -v '{}' "${WASM_OUTPUT_DIR}/" ';' || true

info ">>> Pass 3: Training APIs"
rm -rf "${BUILD_DIR}"
"${BUILD_SH}" "${COMMON_ARGS[@]}" --enable_wasm_simd --enable_wasm_threads --enable_training_apis
find "${BUILD_DIR}/${WASM_CONFIG}" -type f -name "ort-training*" -exec cp -v '{}' "${WASM_OUTPUT_DIR}/" ';' || true

if [ "${ENABLE_ASYNCIFY}" = "true" ]; then
  info ">>> Pass 4: Asyncify-marked (copied if present)"
  rm -rf "${BUILD_DIR}"
  "${BUILD_SH}" "${COMMON_ARGS[@]}" --enable_wasm_simd --enable_wasm_threads
  find "${BUILD_DIR}/${WASM_CONFIG}" -type f \( -name "ort-wasm-simd-threaded.asyncify.*" -o -name "ort-wasm-simd-threaded.*" \) -exec cp -v '{}' "${WASM_OUTPUT_DIR}/" ';' || true
fi

info "WASM artifacts in ${WASM_OUTPUT_DIR}"
ls -alh "${WASM_OUTPUT_DIR}" || true
