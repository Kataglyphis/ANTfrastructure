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

# WebGPU wasm flavor arg sets (LOG2) --------------------------------------------
#
# Upstream's own artifact pipeline (v1.29.0 tools/ci_build/github/azure-pipelines/
# templates/linux-wasm-ci.yml) builds the two browser-WebGPU flavors with a
# REDUCED CPU-fallback op/type set — WebGPU serves the graph, the wasm CPU
# fallback inside these bundles is size-trimmed:
#   '--disable_ml_ops --disable_generation_ops --disable_types string float4
#    float8 optional sparsetensor --include_ops_by_config
#    .../onnxruntime/wasm/reduced_types.config
#    --enable_reduced_operator_type_support'
# Mirrored verbatim so our .asyncify/.jspi artifacts match the official
# onnxruntime-web npm dist semantics.
REDUCED_SIZE_ARGS=(
  "--disable_ml_ops"
  "--disable_generation_ops"
  "--disable_types" "string" "float4" "float8" "optional" "sparsetensor"
  "--include_ops_by_config" "${ORT_SRC_DIR}/onnxruntime/wasm/reduced_types.config"
  "--enable_reduced_operator_type_support"
)

# JSPI refuses to build with wasm exception catching disabled — build.py v1.29.0:
#   "Cannot set WebAssembly exception catching in JSPI build."
# so the JSPI pass gets COMMON_ARGS minus exactly that one flag (upstream's JSPI
# CI leg likewise omits every exception-handling flag).
JSPI_COMMON_ARGS=()
for _arg in "${COMMON_ARGS[@]}"; do
  [ "${_arg}" = "--disable_wasm_exception_catching" ] || JSPI_COMMON_ARGS+=("${_arg}")
done
unset _arg

# The WebGPU flavors are OPTIONAL browser assets layered on top of the always-built
# core flavors (passes 1-3, already copied out before these run). A flavor failure
# must not throw those away: 50-build-js.sh detects a missing flavor's artifacts
# and trims exactly the matching JS bundles (the pre-LOG2 degradation path).
# ORT_WEB_REQUIRED=1 (the existing onnx-web strictness knob) restores hard-fail.
run_optional_flavor_pass() {
  local label="$1"
  shift
  info ">>> ${label}"
  rm -rf "${BUILD_DIR}"
  if "$@"; then
    return 0
  fi
  if [ "${ORT_WEB_REQUIRED:-0}" = "1" ]; then
    err "${label} failed and ORT_WEB_REQUIRED=1"
  fi
  warn "${label} failed — shipping onnxruntime-web WITHOUT this flavor (50-build-js.sh will trim its JS bundles)"
  return 1
}

collect_wasm_artifacts() {
  local pattern="$1"
  find "${BUILD_DIR}/${WASM_CONFIG}" -type f -name "${pattern}" -print0 | xargs -0 cp -t "${WASM_OUTPUT_DIR}/" 2>/dev/null || true
}

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

# Passes 4+5 (LOG2): the REAL WebGPU wasm flavors. ORT v1.29.0's target-naming
# logic (cmake/onnxruntime_webassembly.cmake) appends the flavor suffix itself:
#   USE_JSEP                        -> ort-wasm-simd-threaded.jsep.*     (pass 2)
#   USE_WEBGPU, no JSPI             -> ort-wasm-simd-threaded.asyncify.* (pass 4)
#   USE_WEBGPU + ENABLE_..._JSPI    -> ort-wasm-simd-threaded.jspi.*     (pass 5)
# These are what ort.webgpu*/ort.jspi* JS bundles load at runtime
# (js/web/lib/wasm/wasm-utils-import.ts), letting consumers pick per browser.
# The former fake "Pass 4" (ENABLE_ASYNCIFY: plain build + EMCC asyncify flags,
# COPIED to .asyncify names) is deleted — it shipped a WebGPU-less binary under
# the WebGPU flavor's filename and would mask a failed real flavor build.
if [ "${ORT_WASM_WEBGPU_FLAVORS}" = "true" ]; then
  if run_optional_flavor_pass "Pass 4: WebGPU (asyncify)" \
      "${BUILD_SH}" "${COMMON_ARGS[@]}" --enable_wasm_simd --enable_wasm_threads \
      --use_webgpu --use_webnn --target onnxruntime_webassembly \
      "${REDUCED_SIZE_ARGS[@]}"; then
    collect_wasm_artifacts "ort-wasm-simd-threaded.asyncify.*"
  fi

  if run_optional_flavor_pass "Pass 5: WebGPU (JSPI)" \
      "${BUILD_SH}" "${JSPI_COMMON_ARGS[@]}" --enable_wasm_simd --enable_wasm_threads \
      --use_webgpu --use_webnn --enable_wasm_jspi --target onnxruntime_webassembly \
      "${REDUCED_SIZE_ARGS[@]}"; then
    collect_wasm_artifacts "ort-wasm-simd-threaded.jspi.*"
  fi
else
  info "Skipping WebGPU wasm flavor passes (ORT_WASM_WEBGPU_FLAVORS=${ORT_WASM_WEBGPU_FLAVORS})"
fi

info "WASM artifacts in ${WASM_OUTPUT_DIR}"
ls -alh "${WASM_OUTPUT_DIR}" || true
