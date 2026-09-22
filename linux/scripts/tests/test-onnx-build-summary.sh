#!/usr/bin/env bash
# report_onnx_build_output — the one owner of the closing "what did this stage
# produce" summary the four onnxruntime build scripts print. Run off-target from
# its own source with info() stubbed, plus the pin that no caller keeps a copy.
# docs/code-quality-tooling.md#the-allowlist-contract
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
ORT="${TESTS_DIR}/../03-media/build/onnxruntime/build"
COMMON="${ORT}/lib/common.sh"

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
# The four copies had drifted before this owner existed (one used sed -n '1,20p'
# where the others used head -20), which is exactly what one owner prevents.
_copies="$(grep -l -e '-lh .*wheels.*\*\.whl' \
  "${ORT}/30-build-native.sh" "${ORT}/30-build-native-amd.sh" \
  "${ORT}/30-build-native-nvidia.sh" "${ORT}/60-build-genai.sh" 2>/dev/null || true)"
t_assert_eq "" "${_copies}" "these must call report_onnx_build_output, not re-list the wheels"

t_case "all four build scripts call the owner"
for _s in 30-build-native.sh 30-build-native-amd.sh 30-build-native-nvidia.sh 60-build-genai.sh; do
  t_assert_ok grep -q "report_onnx_build_output " "${ORT}/${_s}"
done


# ── The native ORT builds must not drift apart on the GCC-16 workarounds ─────
# Each native build owns its OWN arg list, so a fix in one silently misses the
# others. --no_telemetry: ORT 1.29 defaults telemetry ON, pulling in a vendored
# sqlite that dies on GCC 16's -Werror=stringop-overflow (the CPU build got this
# 2026-08-19 after it "killed the arm64 media lane 3x"; the GPU build had not).
# append_onnx_optional_lto_webgpu_args: the only place attaching
# -Wno-invalid-constexpr, without which Dawn cannot build under GCC 16.
t_case "every native ORT build disables telemetry (GCC-16 sqlite -Werror)"
for _s in 30-build-native.sh 30-build-native-nvidia.sh 30-build-native-amd.sh; do
  [ -f "${ORT}/${_s}" ] || continue
  t_assert_ok grep -q -- "--no_telemetry" "${ORT}/${_s}"
done

t_case "every native ORT build gets WebGPU/LTO through the shared owner"
for _s in 30-build-native.sh 30-build-native-nvidia.sh; do
  [ -f "${ORT}/${_s}" ] || continue
  t_assert_ok grep -q "append_onnx_optional_lto_webgpu_args" "${ORT}/${_s}"
  # ...and NOT by hand, which is what skipped the Dawn workaround. Comments are
  # stripped first: this very file explains the flag in prose, and a naive grep
  # counts that explanation as the offence it warns about.
  t_assert_eq "0" "$(sed 's/#.*$//' "${ORT}/${_s}" | grep -c -- "--use_external_dawn" || true)" \
    "${_s} must not hand-roll --use_external_dawn; the helper owns it"
done


# ── CUDA builds use the IMAGE's compiler, not a side toolchain ───────────────
# OWNER DIRECTIVE 2026-09-17: always build with the container's own compilers
# (GCC 16). CUDA 13.3's crt/host_config.h refuses __GNUC__ > 15, and the tempting
# fix is CUDAHOSTCXX=g++-15 -- which was tried and is worse: device code then
# links against a different libstdc++ than the rest of the image, and anything
# spanning both dies on `std::__format::…@GLIBCXX_3.4.36`. The supported route is
# -allow-unsupported-compiler via NVCC_PREPEND_FLAGS, which nvcc honours on every
# invocation, so ONE env reaches ORT, OpenCV and TVM alike. Turning warnings off
# is explicitly allowed; switching compilers is not.
t_case "no CUDA lane pins a host compiler other than the image's own"
_DF_MEDIA="${TESTS_DIR}/../../Dockerfile.media"
t_assert_eq "0" "$(sed 's/#.*$//' "${_DF_MEDIA}" | grep -cE 'CUDAHOSTCXX|CUDAHOSTCC' || true)" \
  "Dockerfile.media must not pin nvcc to a side host compiler"
t_assert_ok grep -q "NVCC_PREPEND_FLAGS" "${_DF_MEDIA}"
t_assert_eq "0" "$(sed 's/#.*$//' "${ORT}/30-build-native-nvidia.sh" | grep -cE 'CUDAHOSTCXX|CUDAHOSTCC|ccbin' || true)" \
  "30-build-native-nvidia.sh must not redirect nvcc to another host compiler"

t_case "GenAI's GPU build asks for TRT-RTX only when TensorRT ships"
# --use_trt_rtx names the wheel onnxruntime-genai-trt-rtx, which REQUIRES
# onnxruntime-trt-rtx; the Jetson lane (ENABLE_TENSORRT=false) ships neither.
_GENAI="${TESTS_DIR}/../03-media/build/onnxruntime/build/60-build-genai.sh"
_sel="$(grep -E '^  (_genai_gpu_args=|\[ "\$\{ENABLE_TENSORRT)' "${_GENAI}")"
t_assert_eq 2 "$(printf '%s\n' "${_sel}" | grep -c .)" "the selection is two lines this case can run"
_gargs() { ENABLE_TENSORRT="$1" bash -c "${_sel}"$'\nprintf "%s " "${_genai_gpu_args[@]}"'; }
t_assert_eq "--use_cuda --cuda_home /usr/local/cuda " "$(CUDA_HOME='' _gargs false)" \
  "no TensorRT: a plain CUDA GenAI (no dangling onnxruntime-trt-rtx edge)"
t_assert_contains "$(_gargs true)" "--use_trt_rtx" "TensorRT lanes keep TRT-RTX"
t_assert_contains "$(grep -A4 'ONNX Runtime GenAI GPU build' "${_GENAI}")" '"${_genai_gpu_args[@]}"' \
  "the build call uses the selection"

t_summary
