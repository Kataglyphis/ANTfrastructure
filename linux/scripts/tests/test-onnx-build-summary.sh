#!/usr/bin/env bash
# report_onnx_build_output owns the onnxruntime stage summary; see docs/code-quality-tooling.md#the-allowlist-contract
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
ORT="${TESTS_DIR}/../03-media/build/onnxruntime/build"
COMMON="${ORT}/lib/common.sh"

t_source_functions "${TESTS_DIR}/../01-core/cmake-cache-linker.sh" cmake_assert_configured_entries || exit 1

# Argument fixtures cannot prove a compiled static plugin or device inference.
t_source_functions "${COMMON}" onnx_webgpu_enabled_for_target append_onnx_optional_lto_webgpu_args assert_onnx_webgpu_static_plugin || exit 1
_webgpu_args() {
  local -a _owgp_args=(--config Release 'CALLER=value with spaces')
  ORT_ENABLE_WEBGPU="$1" TARGET_ARCH="$2" ORT_WEBGPU_ALLOW_CROSS="$3" ORT_ENABLE_LTO="$4" \
    append_onnx_optional_lto_webgpu_args _owgp_args
  printf '<%s>' "${_owgp_args[@]}"
}
_wgp_base='<--config><Release><CALLER=value with spaces>'
_wgp_flags='<--use_webgpu><static_plugin><--use_external_dawn><--cmake_extra_defines><CMAKE_CXX_FLAGS=-Wno-error=invalid-constexpr -Wno-invalid-constexpr>'
for _wgp_arch in amd64 x86_64 arm64 riscv64; do
  t_case "${_wgp_arch}: native WebGPU uses the static plugin ABI with external Dawn"
  t_assert_eq "${_wgp_base}${_wgp_flags}" "$(_webgpu_args true "${_wgp_arch}" true false)"
  t_case "${_wgp_arch}: LTO preserves the static plugin argument and caller boundaries"
  t_assert_eq "${_wgp_base}<--enable_lto>${_wgp_flags}" "$(_webgpu_args true "${_wgp_arch}" true true)"
  t_case "${_wgp_arch}: the WebGPU opt-out leaves independent LTO enabled"
  t_assert_eq "${_wgp_base}<--enable_lto>" "$(_webgpu_args false "${_wgp_arch}" true true)"
done
for _wgp_arch in arm64 riscv64; do
  t_case "${_wgp_arch}: an explicit cross opt-out keeps WebGPU disabled"
  t_assert_eq "${_wgp_base}" "$(_webgpu_args true "${_wgp_arch}" false false)"
done
for _wgp_arch in amd64 x86_64; do
  t_case "${_wgp_arch}: the cross guard does not disable native WebGPU"
  t_assert_eq "${_wgp_base}${_wgp_flags}" "$(_webgpu_args true "${_wgp_arch}" false false)"
done

_fn="$(t_fn_src "${COMMON}" report_onnx_build_output)" || exit 1

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
{
  printf 'set -euo pipefail\n'
  printf 'info() { printf "[INFO] %%s\\n" "$*"; }\n'
  printf '%s\n' "${_fn}"
  printf 'report_onnx_build_output "$1" "$2"\n'
} > "${_work}/run.sh"
_run() { bash "${_work}/run.sh" "$1" "$2" 2>&1; }

_out="${_work}/out"
mkdir -p "${_out}/wheels" "${_out}/lib"
: > "${_out}/wheels/onnxruntime-1.29.0-cp312-linux_x86_64.whl"
for _i in $(seq -w 1 25); do : > "${_out}/lib/libort_${_i}.so"; done

t_case "the headline, the wheel directory and the wheels themselves are reported"
_res="$(_run "GPU build complete" "${_out}")"
t_assert_contains "${_res}" "[INFO] GPU build complete. Artifacts in ${_out}"
t_assert_contains "${_res}" "[INFO] Wheels in ${_out}/wheels"
t_assert_contains "${_res}" "onnxruntime-1.29.0-cp312-linux_x86_64.whl"

t_case "the caller owns its own headline wording"
t_assert_contains "$(_run "GenAI build complete" "${_out}")" "GenAI build complete. Artifacts in"

t_case "the library listing is capped at 20 names"
t_assert_eq "20" "$(_run "Build complete" "${_out}" | grep -c '^libort_')" \
  "an unbounded listing buries the summary in a stage log"

t_case "an output tree with no wheels and no lib dir is NOT a stage failure"
mkdir -p "${_work}/bare"
t_assert_eq "0" "$(t_rc bash "${_work}/run.sh" "Build complete" "${_work}/bare")" \
  "every line here is advisory; under set -euo pipefail an unguarded ls would kill the stage"
t_assert_contains "$(_run "Build complete" "${_work}/bare")" "[INFO] Wheels in"

t_case "no build script keeps a second copy of the summary"
# Separate copies drift; one owner is the point.
_copies="$(grep -l -e '-lh .*wheels.*\*\.whl' \
  "${ORT}/30-build-native.sh" \
  "${ORT}/30-build-native-nvidia.sh" "${ORT}/60-build-genai.sh" 2>/dev/null || true)"
t_assert_eq "" "${_copies}" "these must call report_onnx_build_output, not re-list the wheels"

t_case "all three build scripts call the owner"
for _s in 30-build-native.sh 30-build-native-nvidia.sh 60-build-genai.sh; do
  t_assert_ok grep -q "report_onnx_build_output " "${ORT}/${_s}"
done


# Each native build owns its arg list, so every one must carry the GCC 16 workarounds for sqlite and Dawn.
t_case "every native ORT build disables telemetry (GCC-16 sqlite -Werror)"
for _s in 30-build-native.sh 30-build-native-nvidia.sh; do
  t_assert_ok grep -q -- "--no_telemetry" "${ORT}/${_s}"
done

t_case "every native ORT build gets WebGPU/LTO through the shared owner"
for _s in 30-build-native.sh 30-build-native-nvidia.sh; do
  [ -f "${ORT}/${_s}" ] || continue
  t_assert_ok grep -q "append_onnx_optional_lto_webgpu_args" "${ORT}/${_s}"
  # Comments stripped first: the build script explains the flag in prose.
  t_assert_eq "0" "$(sed 's/#.*$//' "${ORT}/${_s}" | grep -c -- "--use_external_dawn" || true)" \
    "${_s} must not hand-roll --use_external_dawn; the helper owns it"
done


# CUDA lanes keep the image's own GCC; see docs/failure-modes.md#nvcc-rejects-the-images-gcc-16
t_case "no CUDA lane pins a host compiler other than the image's own"
_DF_MEDIA="${TESTS_DIR}/../../Dockerfile.media"
t_assert_eq "0" "$(sed 's/#.*$//' "${_DF_MEDIA}" | grep -cE 'CUDAHOSTCXX|CUDAHOSTCC' || true)" \
  "Dockerfile.media must not pin nvcc to a side host compiler"
t_assert_ok grep -q "NVCC_PREPEND_FLAGS" "${_DF_MEDIA}"
t_assert_eq "0" "$(sed 's/#.*$//' "${ORT}/30-build-native-nvidia.sh" | grep -cE 'CUDAHOSTCXX|CUDAHOSTCC|ccbin' || true)" \
  "30-build-native-nvidia.sh must not redirect nvcc to another host compiler"

t_case "GenAI's GPU build never asks for TRT-RTX, with or without TensorRT"
# --use_trt_rtx builds onnxruntime-genai-trt-rtx, which requires onnxruntime-trt-rtx; the chain ORT is onnxruntime-gpu.
_GENAI="${TESTS_DIR}/../03-media/build/onnxruntime/build/60-build-genai.sh"
_sel="$(grep -E '^  _genai_gpu_args' "${_GENAI}")"
t_assert_eq 1 "$(printf '%s\n' "${_sel}" | grep -c .)" "the selection is one line this case can run"
_gargs() { ENABLE_TENSORRT="$1" bash -c "${_sel}"$'\nprintf "%s " "${_genai_gpu_args[@]}"'; }
t_assert_eq "--use_cuda --cuda_home /usr/local/cuda " "$(CUDA_HOME='' _gargs false)" "no TensorRT: a plain CUDA GenAI"
t_assert_eq "--use_cuda --cuda_home /usr/local/cuda " "$(CUDA_HOME='' _gargs true)" "TensorRT: still a plain CUDA GenAI"
t_assert_eq 0 "$(sed 's/#.*$//' "${_GENAI}" | grep -c -- '--use_trt_rtx' || true)" "no line adds --use_trt_rtx"
t_assert_contains "$(grep -A4 'ONNX Runtime GenAI GPU build' "${_GENAI}")" '"${_genai_gpu_args[@]}"' \
  "the build call uses the selection"

# ROCm 10.1's /opt/rocm prefix serves flatbuffers 25, which ort.fbs.h rejects (rocm chain 20261009-131840).
t_case "every native ORT build keeps ORT's pinned flatbuffers"
_base="$(t_fn_src "${COMMON}" append_onnx_native_base_build_args)" || exit 1
_bargs="$(bash -c "${_base}"$'\nA=()\nappend_onnx_native_base_build_args A /b Release 4\nprintf "%s\\n" "${A[@]}"')"
t_assert_contains "${_bargs}" "CMAKE_DISABLE_FIND_PACKAGE_flatbuffers=TRUE" \
  "a found flatbuffers other than ORT's 23.x breaks every flatbuffers TU"

t_case "the CPU build hides a ROCm root from CMake, and only when one exists"
_iso="$(t_fn_src "${COMMON}" append_onnx_rocm_isolation_args)" || exit 1
_isoargs() { ROCM_HOME="$1" bash -c "${_iso}"$'\nA=()\nappend_onnx_rocm_isolation_args A\nprintf "%s" "${A[*]}"'; }
mkdir -p "${_work}/rocm"
t_assert_eq "--cmake_extra_defines CMAKE_IGNORE_PREFIX_PATH=${_work}/rocm" "$(_isoargs "${_work}/rocm")" \
  "the rocm lane's CPU ORT must not take nlohmann_json or flatbuffers from ROCm"
t_assert_eq "" "$(_isoargs "${_work}/no-rocm")" "no ROCm root, no argument"
t_assert_ok grep -q "^append_onnx_rocm_isolation_args BUILD_ARGS" "${ORT}/30-build-native.sh"
t_assert_eq "" "$(ls "${ORT}"/30-build-native-amd.sh 2>/dev/null)" "the in-tree MIGraphX build is gone; the rocm image's GPU EP is the plugin (35)"

# Synthetic caches prove flags and opt-outs, not compiled factories or device availability.
_wgp_build="${_work}/WebGPU build"
mkdir -p "${_wgp_build}"
_webgpu_cache_fixture() {
  printf 'onnxruntime_USE_WEBGPU:BOOL=%s\nonnxruntime_USE_EP_API_ADAPTERS:BOOL=%s\nonnxruntime_WEBGPU_STATIC_PLUGIN:BOOL=%s\nonnxruntime_USE_EXTERNAL_DAWN:BOOL=%s\n' "$1" "$1" "$1" "$1" > "${_wgp_build}/CMakeCache.txt"
}
_webgpu_cache_gate() {
  ORT_ENABLE_WEBGPU="$1" TARGET_ARCH="$2" ORT_WEBGPU_ALLOW_CROSS="$3" assert_onnx_webgpu_static_plugin "${4:-${_wgp_build}}"
}
_webgpu_cache_fixture ON
cp "${_wgp_build}/CMakeCache.txt" "${_wgp_build}/good.txt"
for _arch in amd64 x86_64 arm64 riscv64; do
  t_case "${_arch}: configured native WebGPU requires all static-plugin switches"
  t_assert_ok _webgpu_cache_gate true "${_arch}" true
done
for _key in onnxruntime_USE_WEBGPU onnxruntime_USE_EP_API_ADAPTERS onnxruntime_WEBGPU_STATIC_PLUGIN onnxruntime_USE_EXTERNAL_DAWN; do
  t_case "${_key}: missing, off, mistyped and duplicated options cannot pass"
  for _edit in "/^${_key}:/d" "s/^${_key}:BOOL=ON$/${_key}:BOOL=OFF/" "s/^${_key}:BOOL=/${_key}:STRING=/"; do
    sed "${_edit}" "${_wgp_build}/good.txt" > "${_wgp_build}/CMakeCache.txt"
    t_assert_fails _webgpu_cache_gate true amd64 true
  done
  cat "${_wgp_build}/good.txt" > "${_wgp_build}/CMakeCache.txt"
  printf '%s:BOOL=ON\n' "${_key}" >> "${_wgp_build}/CMakeCache.txt"
  t_assert_fails _webgpu_cache_gate true amd64 true
done
t_case "a missing configure cache is not a pass"
t_assert_fails _webgpu_cache_gate true amd64 true "${_wgp_build}/absent"
t_case "CRLF cache values retain their exact boolean meaning"
sed 's/$/\r/' "${_wgp_build}/good.txt" > "${_wgp_build}/CMakeCache.txt"
t_assert_ok _webgpu_cache_gate true amd64 true
t_case "an opt-out refuses a stale enabled plugin"
t_assert_fails _webgpu_cache_gate false amd64 true
_webgpu_cache_fixture OFF
for _arch in amd64 arm64 riscv64; do
  t_case "${_arch}: the explicit WebGPU opt-out proves every switch is off"
  t_assert_ok _webgpu_cache_gate false "${_arch}" true
done
for _arch in arm64 riscv64; do
  t_case "${_arch}: the cross opt-out proves every switch is off"
  t_assert_ok _webgpu_cache_gate true "${_arch}" false
done
t_case "Emscripten keeps its integrated Dawn while selecting the same static-plugin ABI"
_webgpu_cache_fixture ON
sed -i 's/onnxruntime_USE_EXTERNAL_DAWN:BOOL=ON/onnxruntime_USE_EXTERNAL_DAWN:BOOL=OFF/' "${_wgp_build}/CMakeCache.txt"
t_assert_ok assert_onnx_webgpu_static_plugin "${_wgp_build}" ON OFF
t_assert_fails assert_onnx_webgpu_static_plugin "${_wgp_build}" ON ON
t_assert_rc 2 assert_onnx_webgpu_static_plugin "${_wgp_build}" OFF ON
t_case "the NVIDIA build runs the configured-cache verdict"
t_assert_contains "$(cat "${ORT}/30-build-native-nvidia.sh")" 'assert_onnx_webgpu_static_plugin "${NATIVE_GPU_BUILD_DIR}/${NATIVE_CPU_CONFIG}" || exit 1'
t_case "the ORT bootstrap requires the shared configured-entry reader before build work"
_wgp_preamble="$(sed -n '/^for _req_fn in /,/^unset _req_fn$/p' "${COMMON}")"
t_assert_contains "${_wgp_preamble}" 'cmake_assert_configured_entries'
_webgpu_bootstrap_probe() {
  MISSING_HELPER="$1" bash -c '
    command() { if [ "${2:-}" = "${MISSING_HELPER}" ]; then return 1; fi; return 0; }
    eval "$1"
    printf "bootstrap-complete\n"' _ "${_wgp_preamble}"
}
t_assert_ok _webgpu_bootstrap_probe none
t_assert_fails _webgpu_bootstrap_probe cmake_assert_configured_entries
t_summary
