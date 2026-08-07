#!/usr/bin/env bash
set -euo pipefail

# Source shared modules (container path for runtime images)
if [ -f /opt/scripts/core/modules.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/modules.sh
  source_modules_framework "/opt/scripts/core"
  source_module platform.sh || true
elif [ -f /opt/scripts/core/platform.sh ]; then
  # Fallback: modules.sh not present but platform.sh is (standalone runtime context)
  # shellcheck disable=SC1091
  source /opt/scripts/core/platform.sh
fi

resolve_triplet() {
  local triplet
  if command -v arch_deb_multiarch_triplet_for >/dev/null 2>&1; then
    triplet="$(arch_deb_multiarch_triplet_for "${TARGET_ARCH:-${TARGETARCH:-amd64}}")" && \
      [ -n "${triplet}" ] && { printf '%s' "${triplet}"; return 0; }
  fi
  if command -v deb_multiarch_triplet >/dev/null 2>&1; then
    deb_multiarch_triplet && return 0
  fi
  dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true
}

write_conf() {
  local conf_path="$1"
  shift

  : > "${conf_path}"
  while [ "$#" -gt 0 ]; do
    printf '%s\n' "$1" >> "${conf_path}"
    shift
  done
}

triplet="$(resolve_triplet)"

mkdir -p "/opt/gstreamer/lib/${triplet}"
ln -snf "/opt/gstreamer/lib/${triplet}" "/opt/gstreamer/lib/multiarch" || true

write_conf /etc/ld.so.conf.d/gstreamer.conf "/opt/gstreamer/lib/${triplet}"
write_conf /etc/ld.so.conf.d/libcamera.conf "/opt/libcamera/lib" "/opt/libcamera/lib64"
write_conf /etc/ld.so.conf.d/ffmpeg.conf "/opt/ffmpeg/lib"
write_conf /etc/ld.so.conf.d/opencv.conf "/opt/opencv5/lib"
write_conf /etc/ld.so.conf.d/onnxruntime.conf "/usr/local/lib/onnxruntime-cpu/lib" "/usr/local/lib/onnxruntime-genai/lib"
write_conf /etc/ld.so.conf.d/litert.conf "/usr/local/lib"
write_conf /etc/ld.so.conf.d/gcc.conf "/opt/gcc-${GCC_VERSION:-16.2.0}/lib64" "/opt/gcc-${GCC_VERSION:-16.2.0}/lib"

if [ "${ENABLE_NVIDIA:-false}" = "true" ]; then
  write_conf /etc/ld.so.conf.d/cuda.conf "${CUDA_HOME:-/usr/local/cuda}/lib64"
  write_conf /etc/ld.so.conf.d/tensorrt.conf "${TENSORRT_HOME:-/usr/local/tensorrt}/lib"
elif [ "${ENABLE_AMD:-false}" = "true" ]; then
  write_conf /etc/ld.so.conf.d/migraphx.conf "/opt/rocm/lib" "/opt/rocm/lib64"
fi

ldconfig
