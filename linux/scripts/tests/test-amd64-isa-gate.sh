#!/usr/bin/env bash
# The amd64 baseline gate on probe lines: it grades the compiler default, OpenCV and the loader, never each shipped ELF. docs/amd64-x86-64-v3-baseline.md#the-gates
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SMOKE="${TESTS_DIR}/../06-packaging/smoke-runtime-image.sh"
ISA="${TESTS_DIR}/../06-packaging/check-arch-isa.sh"
OPENCV="${TESTS_DIR}/../03-media/build/opencv/build-opencv.sh"
CPUB="${TESTS_DIR}/../03-media/build/opencv/opencv-cpu-baseline.sh"

eval "$(t_fn_src "${SMOKE}" _smoke_probe_values)"
eval "$(t_fn_src "${ISA}" _x86_baseline_verdicts)"

_CC='X86CC x86-64-v3'
_DEF='X86DEF 3'
_OCV='X86OCV SSE_SSE2_SSE3_SSSE3_SSE4_1_POPCNT_SSE4_2_AVX_FP16_AVX2'
_LD='X86LD _x86-64-v3_(supported,_searched)'
_verdicts() { _x86_baseline_verdicts "$(printf '%s\n' "$@")"; }
_count() { printf '%s\n' "$2" | grep -c -e "^$1 "; }

t_case "a compiler, an OpenCV and a loader that agree on x86-64-v3 pass on four facts"
_o="$(_verdicts "${_CC}" "${_DEF}" "${_OCV}" "${_LD}")"
t_assert_eq "4" "$(_count OK "${_o}")" "cc, defines, opencv, loader"
t_assert_eq "0" "$(_count BAD "${_o}")"

t_case "an image built before the switch is OLD: reported, neither a pass nor a failure"
# The facts read off :latest amd64 on 2026-11-12.
_o="$(_verdicts 'X86CC ' 'X86DEF 0' 'X86OCV SSE_SSE2_SSE3' "${_LD}")"
t_assert_eq "OLD cc generic" "${_o}" "nothing else is graded against a compiler that never asked for it"

t_case "a default cc that predefines less than the gcc claims is BAD"
t_assert_contains "$(_verdicts "${_CC}" 'X86DEF 0' "${_OCV}" "${_LD}")" "BAD defines 0-of-3" "cc is not our gcc"
t_assert_contains "$(_verdicts "${_CC}" "${_OCV}" "${_LD}")" "BAD defines 0-of-3" "a missing fact is not a pass"

t_case "OpenCV at its upstream baseline under a v3 compiler is BAD"
t_assert_contains "$(_verdicts "${_CC}" "${_DEF}" 'X86OCV SSE_SSE2_SSE3' "${_LD}")" "BAD opencv SSE_SSE2_SSE3" \
  "the compiler default does not widen OpenCV's intrinsics"

t_case "unreadable OpenCV build information is a SKIP, never a pass"
_o="$(_verdicts "${_CC}" "${_DEF}" 'X86OCV ' "${_LD}")"
t_assert_contains "${_o}" "SKIP opencv"
t_assert_eq "3" "$(_count OK "${_o}")"

t_case "a loader that does not call x86-64-v3 supported is BAD: the entrypoint check would be blind"
t_assert_contains "$(_verdicts "${_CC}" "${_DEF}" "${_OCV}" 'X86LD _x86-64-v3')" "BAD loader _x86-64-v3"
t_assert_contains "$(_verdicts "${_CC}" "${_DEF}" "${_OCV}")" "BAD loader no-x86-64-v3-line"

t_case "a probe without amd64 facts is NONE, not a vacuous green"
t_assert_contains "$(_x86_baseline_verdicts "")" "NONE"
t_assert_contains "$(_verdicts 'RVCC rva23u64' 'PKG numpy')" "NONE" "unrelated probe lines must not look like coverage"

# ── the renderer both ISA gates share ────────────────────────────────────────
eval "$(t_fn_src "${TESTS_DIR}/../06-packaging/smoke-common.sh" _shipped_verdict_line)"
eval "$(t_fn_src "${ISA}" _x86_baseline_verdict_line)"
eval "$(t_fn_src "${ISA}" _rvv_verdict_line)"
fail() { echo "FAIL $*"; }

t_case "amd64: BAD and NONE fail with the fact, OLD and SKIP only report, OK is silent"
t_assert_contains "$(_x86_baseline_verdict_line 'BAD opencv SSE_SSE2_SSE3')" \
  "FAIL x86-64-v3: opencv disagrees with the image's own compiler default (SSE_SSE2_SSE3)"
t_assert_contains "$(_x86_baseline_verdict_line 'NONE - -')" "FAIL x86-64-v3: the probe printed no amd64 baseline fact"
_o="$(_x86_baseline_verdict_line 'OLD cc generic')"
t_assert_contains "${_o}" "the image's gcc defaults to generic, not x86-64-v3"
t_assert_eq "0" "$(printf '%s\n' "${_o}" | grep -c -e FAIL)" "an image from before the switch is not a failure"
t_assert_contains "$(_x86_baseline_verdict_line 'SKIP opencv no-build-information')" "  ~~   opencv: no-build-information"
t_assert_eq "" "$(_x86_baseline_verdict_line 'OK cc x86-64-v3')"

t_case "riscv64 keeps its wording through the shared renderer"
t_assert_contains "$(_rvv_verdict_line 'BAD libopencv_core.so rv64i2p1_m2p0')" \
  "FAIL RVV: libopencv_core.so was built WITHOUT the vector extension (rv64i2p1_m2p0) -- the image's own glibc requires it"
t_assert_contains "$(_rvv_verdict_line 'OLD x.so rv64i2p1')" "  ~~   x.so predates the RVA23 switch (rv64i2p1); the image's own gcc has no vector default either"
t_assert_contains "$(_rvv_verdict_line 'SKIP libavcodec.so.62 no ISA attribute could be read')" "  ~~   libavcodec.so.62: no ISA attribute could be read"
t_assert_contains "$(_rvv_verdict_line 'NONE - -')" "FAIL RVV: the probe found none of the objects it checks"

t_case "the gate and its probe are wired into the smoke run, amd64-only"
_smoke_src="$(cat "${SMOKE}")"
_isa_src="$(cat "${ISA}")"
t_assert_contains "${_smoke_src}" 'source "${_SCRIPT_DIR}/check-arch-isa.sh"'
t_assert_contains "${_smoke_src}" 'check_amd64_isa "${image_tag}" "${target_arch}"' "an unwired gate is not a gate"
t_assert_contains "${_smoke_src}" "  _probe_amd64_baseline" "a gate without its probe lines reads NONE"
eval "$(t_fn_src "${TESTS_DIR}/../06-packaging/smoke-common.sh" _shipped_arch_gate)"
eval "$(t_fn_src "${ISA}" check_amd64_isa)"
_shipped_truth_verdict_gate() { echo "RAN $1"; }
t_assert_contains "$(check_amd64_isa img amd64)" "RAN amd64 baseline gate could not run"
t_assert_eq "" "$(check_amd64_isa img riscv64)" "another arch has no x86 level"
eval "$(t_fn_src "${ISA}" check_riscv64_isa)"
t_assert_contains "$(check_riscv64_isa img riscv64)" "RAN riscv64 ISA gate could not run"
t_assert_eq "" "$(check_riscv64_isa img amd64)" "amd64 objects carry no RISC-V attribute"
t_assert_contains "${_isa_src}" "with-arch=[a-z0-9_-]+" "x86-64-v3 has hyphens the riscv64 pattern drops"
t_assert_contains "${_isa_src}" "X86OCV %s"

# ── OpenCV: the AVX2 baseline request and its configure check ────────────────
_args_fn="$(t_fn_src "${CPUB}" opencv_amd64_baseline_args)" || exit 1
_assert_fn="$(t_fn_src "${CPUB}" opencv_assert_amd64_baseline)" || exit 1
_args_for() {  # <arch>: the options a core-opts function ends with, through the same nameref chain
  bash -c 'set -euo pipefail; _arch="$2"; cross_target_arch() { printf "%s" "${_arch}"; }; eval "$1"
    _core() { local -n _occmo_out="$1"; _occmo_out=(-DFIRST=1); opencv_amd64_baseline_args _occmo_out; }
    opts=(); _core opts; printf "%s\n" "${opts[@]}"' _ "${_args_fn}" "$1"
}
_log="$(t_mktemp)"
_baseline_check() {  # <arch> <baseline line> [dispatch line]
  printf -- '--   CPU/HW features:\n--     Baseline:                    %s\n--       requested:                 AVX2\n--     Dispatched code generation:  %s\n' \
    "$2" "${3:-AVX512_SKX}" > "${_log}"
  bash -c 'set -euo pipefail; _arch="$2"; cross_target_arch() { printf "%s" "${_arch}"; }; eval "$1"; opencv_assert_amd64_baseline "$3"' \
    _ "${_assert_fn}" "$1" "${_log}"
}

t_case "only amd64 asks OpenCV for the AVX2 baseline"
t_assert_eq "-DFIRST=1 -DCPU_BASELINE=AVX2" "$(_args_for amd64 | tr '\n' ' ' | sed 's/ $//')"
t_assert_eq "-DFIRST=1" "$(_args_for riscv64 | tr '\n' ' ' | sed 's/ $//')" "riscv64 has its own baseline arm"
t_assert_eq "-DFIRST=1" "$(_args_for arm64 | tr '\n' ' ' | sed 's/ $//')"

t_case "an amd64 configure that took the AVX2 baseline passes and says so"
t_assert_contains "$(t_out _baseline_check amd64 'SSE SSE2 SSE3 SSSE3 SSE4_1 POPCNT SSE4_2 AVX FP16 AVX2')" "OpenCV baseline: SSE SSE2"

t_case "a configure that fell back fails, also when AVX2 is only dispatched"
t_assert_fails _baseline_check amd64 'SSE SSE2 SSE3'
t_assert_contains "$(t_out _baseline_check amd64 'SSE SSE2 SSE3')" "without AVX2 although CPU_BASELINE=AVX2 was requested"
t_assert_fails _baseline_check amd64 'SSE SSE2 SSE3' 'SSE4_1 SSE4_2 AVX FP16 AVX2 AVX512_SKX'
t_assert_fails _baseline_check amd64 ''

t_case "no other arch is graded"
t_assert_ok _baseline_check riscv64 'RVV'
t_assert_ok _baseline_check arm64 'NEON FP16'

t_case "build-opencv.sh loads the companion, makes the request and runs the check"
_ocv_src="$(cat "${OPENCV}")"
t_assert_contains "${_ocv_src}" 'source "${SCRIPT_DIR}/opencv-cpu-baseline.sh"'
t_assert_contains "$(t_fn_src "${OPENCV}" _opencv_cmake_core_opts)" "opencv_amd64_baseline_args _occmo_out"
t_assert_contains "${_ocv_src}" 'opencv_assert_amd64_baseline "${build_dir}/opencv-configure.log"' \
  "a check nothing calls is not a check"

t_summary
