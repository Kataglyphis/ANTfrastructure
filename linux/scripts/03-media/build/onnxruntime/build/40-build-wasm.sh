#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

parse_common_args "$@"
detect_jobs

# The wasm ccache dir rides the shared S3 level as one archive per ORT version (sccache cannot parse emcc's -Xclang -iwithsysroot, CON173 2026-10-29).
_ort_wasm_ccache_archive() {
  printf 'ccache/onnxruntime-web-%s.tar.gz' "${ORT_VERSION:-unknown}"
}

# An empty ccache dir (a fresh host, a pruned mount) starts from the archive; a warm one is left alone.
_ort_wasm_ccache_restore() {
  command -v sccache_s3_fetch >/dev/null 2>&1 || return 0
  if [ -n "$(ls -A "${CCACHE_DIR}" 2>/dev/null)" ]; then
    info "ccache-s3| ${CCACHE_DIR} is warm; no restore from $(_ort_wasm_ccache_archive)"
    return 0
  fi
  local tmp rc=0
  tmp="$(mktemp)"
  sccache_s3_fetch "$(_ort_wasm_ccache_archive)" "${tmp}" || rc=$?
  case "${rc}" in
    0) tar -xzf "${tmp}" -C "${CCACHE_DIR}" && info "ccache-s3| restored $(_ort_wasm_ccache_archive) ($(du -sh "${CCACHE_DIR}" | cut -f1)) into ${CCACHE_DIR}" ;;
    1) info "ccache-s3| no S3 level in this RUN; ccache stays on the mount" ;;
    *) info "ccache-s3| no $(_ort_wasm_ccache_archive) in the S3 level yet; this build fills it" ;;
  esac
  rm -f "${tmp}"
  return 0
}

# New objects since the restore go up as the whole dir, one archive; nothing new, nothing sent.
_ort_wasm_ccache_store() {
  command -v sccache_s3_store >/dev/null 2>&1 || return 0
  if [ -z "$(find "${CCACHE_DIR}" -type f -newer "${_ORT_WASM_CCACHE_MARK}" -print -quit 2>/dev/null)" ]; then
    info "ccache-s3| nothing new in ${CCACHE_DIR}; $(_ort_wasm_ccache_archive) left as is"
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  if tar -czf "${tmp}" -C "${CCACHE_DIR}" . && sccache_s3_store "$(_ort_wasm_ccache_archive)" "${tmp}"; then
    info "ccache-s3| stored $(_ort_wasm_ccache_archive) ($(du -h "${tmp}" | cut -f1)) in the S3 level"
  else
    warn "ccache-s3| could not store $(_ort_wasm_ccache_archive); the objects stay on this host's mount"
  fi
  rm -f "${tmp}"
  return 0
}

# Emscripten puts this in front of every clang call (emcc.py, config.COMPILER_WRAPPER); ccache, as its docs say: sccache cannot cache emcc at all (CON173).
_ORT_WASM_CCACHE_MARK=""
if command -v ccache >/dev/null 2>&1 && mkdir -p "${CCACHE_DIR:-/var/cache/ccache}/onnxruntime-web" 2>/dev/null; then
  export CCACHE_DIR="${CCACHE_DIR:-/var/cache/ccache}/onnxruntime-web"
  export EM_COMPILER_WRAPPER="ccache"
  # A fresh clone gives every header a new mtime and CMake's probes a new temp dir; neither changes the object.
  export CCACHE_NOHASHDIR=1 CCACHE_SLOPPINESS="time_macros,include_file_mtime,include_file_ctime"
  info "EM_COMPILER_WRAPPER=ccache (emcc's clang calls go through ccache on ${CCACHE_DIR})"
  _ort_wasm_ccache_restore
  _ORT_WASM_CCACHE_MARK="$(mktemp)"
fi

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
  shift
  local names=(-name "$pattern")
  for pattern in "$@"; do names+=(-o -name "$pattern"); done
  find "${BUILD_DIR}/${WASM_CONFIG}" -type f '(' "${names[@]}" ')' -print0 | xargs -0 cp -t "${WASM_OUTPUT_DIR}/" 2>/dev/null || true
}

mkdir -p "${WASM_OUTPUT_DIR}"
rm -rf "${BUILD_DIR}" || true

info ">>> Pass 1: SIMD + Threads"
rm -rf "${BUILD_DIR}"
"${BUILD_SH}" "${COMMON_ARGS[@]}" --enable_wasm_simd --enable_wasm_threads
collect_wasm_artifacts "ort-wasm-simd-threaded.*"

info ">>> Pass 2: JSEP (WebGPU/WebNN)"
rm -rf "${BUILD_DIR}"
"${BUILD_SH}" "${COMMON_ARGS[@]}" --enable_wasm_simd --enable_wasm_threads --use_jsep --use_webnn
collect_wasm_artifacts "ort-wasm-simd-threaded.jsep.*" "ort-wasm-simd-threaded.webnn.*"

# No training pass: upstream deprecated on-device training and removed it from onnxruntime-web (CON94, dropped 2026-10-13).

# ORT's CMake names the WebGPU outputs .asyncify/.jspi itself; the ort.webgpu*/ort.jspi* bundles load them.
if [ "${ORT_WASM_WEBGPU_FLAVORS}" = "true" ]; then
  if run_optional_flavor_pass "Pass 3: WebGPU (asyncify)" \
      "${BUILD_SH}" "${COMMON_ARGS[@]}" --enable_wasm_simd --enable_wasm_threads \
      --use_webgpu --use_webnn --target onnxruntime_webassembly \
      "${REDUCED_SIZE_ARGS[@]}"; then
    collect_wasm_artifacts "ort-wasm-simd-threaded.asyncify.*"
  fi

  if run_optional_flavor_pass "Pass 4: WebGPU (JSPI)" \
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
# The RUN's measurement, as sccache-stats| is for the other RUNs; then the dir goes up.
if [ -n "${EM_COMPILER_WRAPPER:-}" ]; then
  ccache -s 2>/dev/null | grep -E "Hits|Misses|Cacheable|Uncacheable" | sed 's/^/ccache-stats| /' || true
  # 70 % of emcc's calls were uncacheable on 2026-10-29; the verbose breakdown names why (CON173).
  ccache -s -v 2>/dev/null | sed -n '/^Uncacheable/,/^[A-Z]/p' | grep -E "^\s+[A-Za-z]" | sed 's/^/ccache-stats|   why uncacheable: /' || true
  _ort_wasm_ccache_store
  rm -f "${_ORT_WASM_CCACHE_MARK}"
fi
