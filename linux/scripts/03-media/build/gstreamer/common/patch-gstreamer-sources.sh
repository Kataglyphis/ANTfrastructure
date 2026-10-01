#!/usr/bin/env bash
set -euo pipefail

# Docker builds flatten the tree under /opt/scripts, so the repo-relative paths only work standalone.
if [ -f "/opt/scripts/core/apply-patch.sh" ] && [ -d "/opt/scripts/patches/gstreamer" ]; then
    _apply_patch="/opt/scripts/core/apply-patch.sh"
    _patch_dir="/opt/scripts/patches/gstreamer"
else
    _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _apply_patch="${_script_dir}/../../../../01-core/apply-patch.sh"
    _patch_dir="${_script_dir}/../../../../patches/gstreamer"
fi

patch_gstreamer_sources() {
  local repo_root="$1"

  [ -d "${repo_root}" ] || {
    echo "ERROR: GStreamer repo root not found: ${repo_root}" >&2
    return 1
  }

  # 002: Tighten LAME probe (require libmp3lame, not just header)
  [ -f "${repo_root}/subprojects/gst-plugins-good/ext/lame/meson.build" ] && \
    bash "${_apply_patch}" "${_patch_dir}/002-lame-probe-tighten.patch" "${repo_root}" \
      "LAME probe tightening"

  # 003: cargo_wrapper.py CROSS_RUST_TARGET forwarding
  [ -f "${repo_root}/subprojects/gst-plugins-rs/cargo_wrapper.py" ] && \
    bash "${_apply_patch}" "${_patch_dir}/003-cargo-wrapper-cross-rust-target.patch" "${repo_root}" \
      "cargo_wrapper.py CROSS_RUST_TARGET forwarding"

  # 004: gst-plugins-rs meson.build CARGO_BUILD_TARGET extra_env
  [ -f "${repo_root}/subprojects/gst-plugins-rs/meson.build" ] && \
    bash "${_apply_patch}" "${_patch_dir}/004-meson-build-cargo-build-target.patch" "${repo_root}" \
      "gst-plugins-rs meson.build CARGO_BUILD_TARGET"

  # 005a: OpenCV 5 — gstsegmentation geometry.hpp include
  [ -f "${repo_root}/subprojects/gst-plugins-bad/ext/opencv/gstsegmentation.cpp" ] && \
    bash "${_apply_patch}" "${_patch_dir}/005a-opencv5-segmentation-geometry-include.patch" "${repo_root}" \
      "OpenCV 5 segmentation geometry include"

  # 005b: OpenCV 5 — gstcameracalibrate objdetect.hpp include
  [ -f "${repo_root}/subprojects/gst-plugins-bad/ext/opencv/gstcameracalibrate.cpp" ] && \
    bash "${_apply_patch}" "${_patch_dir}/005b-opencv5-cameracalibrate-objdetect-include.patch" "${repo_root}" \
      "OpenCV 5 cameracalibrate objdetect include"

  # 005c: OpenCV 5 — remove cascade-only elements (faceblur/facedetect/handdetect)
  [ -f "${repo_root}/subprojects/gst-plugins-bad/ext/opencv/meson.build" ] && \
    bash "${_apply_patch}" "${_patch_dir}/005c-opencv5-remove-cascade-elements.patch" "${repo_root}" \
      "OpenCV 5 remove cascade elements"

  # 006: gst-libav fallback defines for removed FFmpeg codec IDs (V308/V408/V410)
  if [ -f "${repo_root}/subprojects/gst-libav/ext/libav/gstavvidenc.c" ]; then
    bash "${_apply_patch}" "${_patch_dir}/006-libav-removed-codec-fallbacks.patch" "${repo_root}" \
      "gst-libav removed codec fallbacks"
  fi

  # 007: the SSIM validate plugin fails init in the core registry, which blacklists it; docs/upstreamable-patches.md#22-gst-devtools-the-ssim-validate-plugin-fails-init-outside-gst-validate
  if [ -f "${repo_root}/subprojects/gst-devtools/validate/plugins/ssim/gstvalidatessim.c" ]; then
    bash "${_apply_patch}" "${_patch_dir}/007-validate-ssim-register-outside-validate.patch" "${repo_root}" \
      "gst-devtools ssim plugin registers outside gst-validate"
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  repo_root="${1:-$PWD}"
  patch_gstreamer_sources "${repo_root}"
fi
