#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

parse_common_args "$@"
detect_jobs

# wasm32 output ignores the target arch, so whichever arch finds the shared cache empty builds it for all.

cd "${ORT_SRC_DIR}"

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

# The WebGPU flavors mirror upstream's size-trimmed CPU fallback, so they match the official onnxruntime-web dist.
REDUCED_SIZE_ARGS=(
  "--disable_ml_ops"
  "--disable_generation_ops"
  "--disable_types" "string" "float4" "float8" "optional" "sparsetensor"
  "--include_ops_by_config" "${ORT_SRC_DIR}/onnxruntime/wasm/reduced_types.config"
  "--enable_reduced_operator_type_support"
)

# build.py refuses JSPI with any wasm exception-catching flag, so the JSPI pass drops that one.
JSPI_COMMON_ARGS=()
for _arg in "${COMMON_ARGS[@]}"; do
  [ "${_arg}" = "--disable_wasm_exception_catching" ] || JSPI_COMMON_ARGS+=("${_arg}")
done
unset _arg

# A failed WebGPU flavor must not discard the core passes; 50-build-js.sh trims its bundles instead.
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

# ORT's CMake names the WebGPU outputs .asyncify/.jspi itself; the ort.webgpu*/ort.jspi* bundles load them.
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
