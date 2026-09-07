#!/usr/bin/env bash
# The two riscv64 workarounds F1 named as seams inside _opencv_target_adjustments:
# a static target harfbuzz for the freetype module, and an EXTERNAL libpng because
# OpenCV 5.x's vendored copy fails its RVV configure probe under GCC 16.1.0. Both
# are fail-EARLY by design -- a PNG-less OpenCV only surfaces as a red runtime
# smoke a stage later. docs/cross-build-verification.md#the-linuxscriptstests-suites
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="${TESTS_DIR}/../03-media/build/opencv/build-opencv.sh"

_ft="$(t_fn_src "${SUBJECT}" _ota_riscv64_freetype)" || exit 1
_png="$(t_fn_src "${SUBJECT}" _ota_riscv64_png)" || exit 1

# Both helpers read ABSOLUTE /usr/<triplet> paths, so no host fixture can stand in
# for a staged sysroot -- only a chroot could. What IS testable, and what the two
# seams actually own, is the DECISION: with nothing staged, does each one take its
# named fallback and say why? The triplet stub points them at a name that exists
# nowhere, which is the not-staged case for both.
_ft_run()  { bash -c '
    set -u
    cross_target_triplet() { printf "nosuch-triplet"; }
    '"${_ft}"'
    opts=(); _ota_riscv64_freetype opts; printf "%s\n" "${opts[@]:-}"' 2>&1; }
_png_run() { OPENCV_ALLOW_NO_PNG="${1:-0}" bash -c '
    set -u
    cross_target_triplet() { printf "nosuch-triplet"; }
    '"${_png}"'
    opts=(); _ota_riscv64_png opts; printf "%s\n" "${opts[@]:-}"
    printf "RC=%s\n" "$?"' 2>&1; }

t_case "freetype: nothing staged means the module goes OFF, loudly"
_out="$(_ft_run)"
t_assert_contains "${_out}" "-DBUILD_opencv_freetype=OFF"
t_assert_contains "${_out}" "static target harfbuzz not staged" \
  "the WARN names each missing file; a silent OFF is how this went unnoticed"

t_case "png: absent and not opted out is a HARD failure, not a silent WITH_PNG=OFF"
_out="$(_png_run 0)"
t_assert_contains "${_out}" "external static libpng NOT found"
t_assert_contains "${_out}" "Failing early instead of shipping a PNG-less OpenCV" \
  "failing LATE here cost iree-0714a..e; the smoke is a stage away"
t_assert_eq "0" "$(printf '%s\n' "${_out}" | grep -c -e '^RC=' || true)" \
  "it must exit, not return -- a return would let the build continue"

t_case "png: OPENCV_ALLOW_NO_PNG=1 is the deliberate opt-out, and says so"
_out="$(_png_run 1)"
t_assert_contains "${_out}" "-DWITH_PNG=OFF"
t_assert_contains "${_out}" "cv2 PNG encode unavailable"
t_assert_contains "${_out}" "RC=0" "the opt-out continues the build"

t_case "both seams append to the CALLER's array, they do not print flags"
# A nameref out-array is what lets them stay separate functions; printing would
# put the flags in a subshell the caller throws away (the YB/launcher defect).
for _src in "${_ft}" "${_png}"; do
  t_assert_contains "${_src}" "local -n" "the out-array is a nameref"
done

t_case "and _opencv_target_adjustments actually calls both"
# An extraction that forgets its call site is two functions' worth of riscv64
# knowledge that stops reaching the cmake line, on the one arch nobody runs locally.
_ota="$(t_fn_src "${SUBJECT}" _opencv_target_adjustments)" || exit 1
t_assert_contains "${_ota}" "_ota_riscv64_freetype _ota_cmake_opts"
t_assert_contains "${_ota}" "_ota_riscv64_png _ota_cmake_opts"

t_summary
