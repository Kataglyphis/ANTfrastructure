#!/usr/bin/env bash
# Tests for the riscv64 ISA gate in 06-packaging/smoke-runtime-image.sh. The
# attribute strings below were read off the shipped image on 2026-09-01: apt's
# libc HAS the vector extension, our own pre-RVA23 OpenCV did not.
# See docs/riscv64-rva23-baseline.md.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SMOKE="${TESTS_DIR}/../06-packaging/smoke-runtime-image.sh"

eval "$(sed -n '/^_rvv_verdicts()/,/^}/p' "${SMOKE}")"

_UBUNTU_LIBC='rv64i2p1_m2p0_a2p1_f2p2_d2p2_c2p0_b1p0_v1p0_zicond1p0_zvl128b1p0'
_OLD_OPENCV='rv64i2p1_m2p0_a2p1_f2p2_d2p2_c2p0_zicsr2p0_zifencei2p0_zmmul1p0_zaamo1p0_zalrsc1p0_zca1p0_zcd1p0'

t_case "an object built WITH the vector extension passes"
t_assert_contains "$(_rvv_verdicts "RVARCH libc.so.6 ${_UBUNTU_LIBC}")" "OK libc.so.6"

t_case "a non-vector object FAILS once the image's own gcc defaults to RVA23"
t_assert_contains "$(_rvv_verdicts "RVCC rva23u64_zifencei
RVARCH libopencv_core.so ${_OLD_OPENCV}")" "BAD libopencv_core.so" \
  "after the switch a sub-baseline object is a regression"

t_case "the same object is only reported OLD while the image predates the switch"
# Scoping this to the image's OWN toolchain is what keeps the gate from failing
# images built before the RVA23 change -- without it, it would have broken the
# in-flight 2026-09-01 repair run, which rebuilds no compiler.
t_assert_contains "$(_rvv_verdicts "RVCC
RVARCH libopencv_core.so ${_OLD_OPENCV}")" "OLD libopencv_core.so"

t_case "OLD is not silently equivalent to OK"
_o="$(_rvv_verdicts "RVCC
RVARCH x.so ${_OLD_OPENCV}")"
case "${_o}" in OK*) t_assert_eq "not-OK" "${_o}" "a pre-switch object must not report OK" ;;
  *) t_assert_eq "0" "0" "OLD is its own verdict" ;; esac

t_case "rv64gcv also counts as vector (v1p0 is what is asserted)"
t_assert_contains "$(_rvv_verdicts "RVARCH x.so rv64i2p1_m2p0_a2p1_f2p2_d2p2_c2p0_v1p0_zvl128b1p0")" "OK x.so"

t_case "an unreadable attribute is a SKIP, never a pass"
t_assert_contains "$(_rvv_verdicts "RVARCH libavcodec.so.62 ")" "SKIP libavcodec.so.62"

t_case "a probe that found nothing is NONE, not a vacuous green"
t_assert_contains "$(_rvv_verdicts "")" "NONE"
t_assert_contains "$(_rvv_verdicts "PKG numpy")" "NONE" "unrelated probe lines must not look like coverage"

t_case "the gate is wired into the smoke run and is riscv64-only"
t_assert_contains "$(cat "${SMOKE}")" 'check_riscv64_isa "${image_tag}" "${target_arch}"' \
  "an unwired gate is not a gate"
t_assert_contains "$(cat "${SMOKE}")" '[ "${target_arch}" = riscv64 ] || return 0'

t_case "the probe emits RVARCH lines for the objects that matter"
_probe_src="$(cat "${SMOKE}")"
t_assert_contains "${_probe_src}" "libopencv_core.so"
t_assert_contains "${_probe_src}" "libavcodec.so"
t_assert_contains "${_probe_src}" "RVARCH %s %s"

t_summary
