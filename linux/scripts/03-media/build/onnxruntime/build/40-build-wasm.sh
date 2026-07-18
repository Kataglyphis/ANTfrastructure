#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

parse_common_args "$@"
detect_jobs

# WASM is arch-INDEPENDENT: emscripten targets wasm32 and this always runs on the
# amd64 BUILD host (cross-builds use --platform linux/amd64), so the TARGET arch is
# irrelevant to the output. We therefore no longer skip on a non-amd64 target — the
# Dockerfile drives build-once via a shared cache mount, and letting whichever arch
# reaches an EMPTY cache first do the compile guarantees every arch ends up with the
# assets (fixes arm64/riscv64 racing ahead of amd64 and shipping without onnx-web).
# The only hard requirement is a usable emscripten toolchain, checked below.

cd "${ORT_SRC_DIR}"

# If emsdk exists in repo, ensure env is set for this shell
EMSDK_DIR="${ORT_SRC_DIR}/cmake/external/emsdk"
if [ -d "${EMSDK_DIR}" ] && [ -f "${EMSDK_DIR}/emsdk_env.sh" ]; then
  # shellcheck disable=SC1091
  source "${EMSDK_DIR}/emsdk_env.sh" || true
fi

BUILD_SH="${ORT_SRC_DIR}/build.sh"
[ -x "${BUILD_SH}" ] || err "build.sh not found or not executable at ${BUILD_SH}"

copy_variant_alias_if_missing() {
  local source_path="$1"
  local alias_path="$2"

  [ -f "${source_path}" ] || return 0
  [ -e "${alias_path}" ] && return 0

  cp -v "${source_path}" "${alias_path}"
}

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

info ">>> Pass 1: SIMD + Threads"
rm -rf "${BUILD_DIR}"
"${BUILD_SH}" "${COMMON_ARGS[@]}" --enable_wasm_simd --enable_wasm_threads
find "${BUILD_DIR}/${WASM_CONFIG}" -type f -name "ort-wasm-simd-threaded.*" -print0 | xargs -0 cp -t "${WASM_OUTPUT_DIR}/" 2>/dev/null || true

info ">>> Pass 2: JSEP (WebGPU/WebNN)"
rm -rf "${BUILD_DIR}"
"${BUILD_SH}" "${COMMON_ARGS[@]}" --enable_wasm_simd --enable_wasm_threads --use_jsep --use_webnn
find "${BUILD_DIR}/${WASM_CONFIG}" -type f \( -name "ort-wasm-simd-threaded.jsep.*" -o -name "ort-wasm-simd-threaded.webnn.*" \) -print0 | xargs -0 cp -t "${WASM_OUTPUT_DIR}/" 2>/dev/null || true

info ">>> Pass 3: Training APIs"
rm -rf "${BUILD_DIR}"
"${BUILD_SH}" "${COMMON_ARGS[@]}" --enable_wasm_simd --enable_wasm_threads --enable_training_apis
find "${BUILD_DIR}/${WASM_CONFIG}" -type f -name "ort-training*" -print0 | xargs -0 cp -t "${WASM_OUTPUT_DIR}/" 2>/dev/null || true

if [ "${ENABLE_ASYNCIFY}" = "true" ]; then
  info ">>> Pass 4: Asyncify-marked (ASYNCIFY_STACK_SIZE=${ASYNCIFY_STACK_SIZE})"
  rm -rf "${BUILD_DIR}"
  asyncify_flags="-s ASYNCIFY=1 -s ASYNCIFY_STACK_SIZE=${ASYNCIFY_STACK_SIZE}"
  EMCC_CFLAGS="${asyncify_flags}" EMCC_LINKER_FLAGS="${asyncify_flags}" \
    "${BUILD_SH}" "${COMMON_ARGS[@]}" --enable_wasm_simd --enable_wasm_threads
  copy_variant_alias_if_missing \
    "${BUILD_DIR}/${WASM_CONFIG}/ort-wasm-simd-threaded.mjs" \
    "${BUILD_DIR}/${WASM_CONFIG}/ort-wasm-simd-threaded.asyncify.mjs"
  copy_variant_alias_if_missing \
    "${BUILD_DIR}/${WASM_CONFIG}/ort-wasm-simd-threaded.mjs.bak" \
    "${BUILD_DIR}/${WASM_CONFIG}/ort-wasm-simd-threaded.asyncify.mjs.bak"
  copy_variant_alias_if_missing \
    "${BUILD_DIR}/${WASM_CONFIG}/ort-wasm-simd-threaded.wasm" \
    "${BUILD_DIR}/${WASM_CONFIG}/ort-wasm-simd-threaded.asyncify.wasm"
  find "${BUILD_DIR}/${WASM_CONFIG}" -type f -name "ort-wasm-simd-threaded.asyncify.*" -print0 | xargs -0 cp -t "${WASM_OUTPUT_DIR}/" 2>/dev/null || true
fi

info "WASM artifacts in ${WASM_OUTPUT_DIR}"
ls -alh "${WASM_OUTPUT_DIR}" || true
