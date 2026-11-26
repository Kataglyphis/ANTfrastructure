#!/usr/bin/env bash
# The riscv64 seams fail early: a PNG-less OpenCV only shows a stage later; see docs/cross-build-verification.md#the-linuxscriptstests-suites
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="${TESTS_DIR}/../03-media/build/opencv/build-opencv.sh"

_ft="$(t_fn_src "${SUBJECT}" _ota_riscv64_freetype)" || exit 1
_png="$(t_fn_src "${SUBJECT}" _ota_riscv64_png)" || exit 1

# Both read absolute /usr/<triplet> paths, so only the decision is tested: a bogus triplet means nothing is staged.
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
# Printed flags would land in a subshell the caller throws away.
for _src in "${_ft}" "${_png}"; do
  t_assert_contains "${_src}" "local -n" "the out-array is a nameref"
done

t_case "and _opencv_target_adjustments actually calls both"
# A forgotten call site silently drops the riscv64 fixes from the cmake line.
_ota="$(t_fn_src "${SUBJECT}" _opencv_target_adjustments)" || exit 1
t_assert_contains "${_ota}" "_ota_riscv64_freetype _ota_cmake_opts"
t_assert_contains "${_ota}" "_ota_riscv64_png _ota_cmake_opts"

t_case "deps: riscv64 names libtiff6 beside libtiff-dev, which apt 3's solver refuses alone after a security update"
DEPS="${TESTS_DIR}/../03-media/build/opencv/install-deps.sh"
_deps_run() { bash -c '
    set -u
    is_cross() { return 0; }
    _arch="$1"; cross_target_arch() { printf "%s" "${_arch}"; }
    '"$(sed -n '/^target_packages=(/,/^fi$/p' "${DEPS}")"'
    printf "%s\n" "${target_packages[@]}"' _ "$1" 2>/dev/null; }
_pk="$(_deps_run riscv64)"
t_assert_contains "${_pk}" "libtiff6"
t_assert_eq "libtiff6" "$(printf '%s\n' "${_pk}" | grep -m1 -e '^libtiff')" "the runtime library is named, ahead of its -dev"
t_assert_eq "0" "$(_deps_run arm64 | grep -cx -e 'libtiff6' || true)" "arm64 keeps its list"

t_summary
