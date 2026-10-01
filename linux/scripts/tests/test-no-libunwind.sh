#!/usr/bin/env bash
# GStreamer and libcamera build without libunwind, and the smoke fails a shipped file that needs it; recorded probe text, not a real image scan.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GST="${TESTS_DIR}/../03-media/build/gstreamer/common/build-gstreamer-monorepo.sh"
CAM="${TESTS_DIR}/../03-media/build/libcamera/build-libcamera.sh"
RT_SMOKE="${TESTS_DIR}/../06-packaging/smoke-runtime-image.sh"

t_case "GStreamer core is configured without libunwind"
_flags="$(t_fn_src "${GST}" _gst_monorepo_meson_base_flags)" || exit 1
t_assert_contains "${_flags}" '"-Dgstreamer:libunwind=disabled"' \
  "libgstreamer's NEEDED libunwind.so.8 put it ahead of libgcc_s; nvinfer's error path segfaulted (2026-10-01)"

t_case "libcamera is configured without libunwind"
t_assert_contains "$(sed -n '/^MESON_SETUP_ARGS=(/,/^)/p' "${CAM}")" '-Dlibunwind=disabled' \
  "a C host that loads libcamera-base first crashed the same way, even with RTLD_LOCAL (measured 2026-10-01)"

_SB="$(t_rt_sandbox)"; trap 'rm -rf "${_SB}"' EXIT
_scan() { t_rt_recorded "${_SB}" "$1" check_no_libunwind_closure img amd64; }

t_case "the smoke runs the libunwind scan"
t_assert_contains "$(t_fn_src "${RT_SMOKE}" main)" 'check_no_libunwind_closure "${image_tag}" "${target_arch}"'

t_case "a clean scan passes, and names how many files it read"
_out="$(_scan $'SCANNED 1234\nUNWIND_SCAN_DONE')"
t_assert_contains "${_out}" "FAILURES=0"
t_assert_contains "${_out}" "none of 1234 shared objects"

t_case "a shipped file that needs libunwind.so.8 fails, by name"
_out="$(_scan $'SCANNED 1234\nNEEDS /opt/libcamera/lib/x86_64-linux-gnu/libcamera-base.so.0.7.2\nUNWIND_SCAN_DONE')"
t_assert_contains "${_out}" "FAILURES=1"
t_assert_contains "${_out}" "/opt/libcamera/lib/x86_64-linux-gnu/libcamera-base.so.0.7.2"

t_case "a scan that did not finish, or read nothing, is not a pass"
t_assert_contains "$(_scan 'SCANNED 1234')" "FAILURES=1" "no completion stamp"
t_assert_contains "$(_scan 'NO_READELF')" "FAILURES=1" "no readelf in the image"
t_assert_contains "$(_scan $'SCANNED 0\nUNWIND_SCAN_DONE')" "FAILURES=1" "an empty scan proves nothing"

t_summary
