#!/usr/bin/env bash
# GStreamer and libcamera build without libunwind; see docs/failure-modes.md#an-exception-through-stdcall_once-segfaults-in-libunwind
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GST="${TESTS_DIR}/../03-media/build/gstreamer/common/build-gstreamer-monorepo.sh"
CAM="${TESTS_DIR}/../03-media/build/libcamera/build-libcamera.sh"

t_case "GStreamer core is configured without libunwind"
_flags="$(t_fn_src "${GST}" _gst_monorepo_meson_base_flags)" || exit 1
t_assert_contains "${_flags}" '"-Dgstreamer:libunwind=disabled"' \
  "libgstreamer's NEEDED libunwind.so.8 put it ahead of libgcc_s; nvinfer's error path segfaulted (2026-10-01)"

t_case "libcamera is configured without libunwind"
t_assert_contains "$(sed -n '/^MESON_SETUP_ARGS=(/,/^)/p' "${CAM}")" '-Dlibunwind=disabled' \
  "a process that loads libcamera-base first crashed the same way, even with RTLD_LOCAL"

t_summary
