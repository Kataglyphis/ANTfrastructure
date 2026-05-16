#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/platform.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/platform.sh
fi

resolve_triplet() {
  if command -v deb_multiarch_triplet >/dev/null 2>&1; then
    deb_multiarch_triplet
    return 0
  fi

  case "${TARGET_ARCH:-${TARGETARCH:-$(uname -m 2>/dev/null || echo unknown)}}" in
    amd64|x86_64) printf '%s' "x86_64-linux-gnu" ;;
    arm64|aarch64) printf '%s' "aarch64-linux-gnu" ;;
    riscv64|riscv) printf '%s' "riscv64-linux-gnu" ;;
    *) dpkg-architecture -q DEB_HOST_MULTIARCH ;;
  esac
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
write_conf /etc/ld.so.conf.d/opencv.conf "/opt/opencv4/lib"
write_conf /etc/ld.so.conf.d/onnxruntime.conf "/usr/local/lib/onnxruntime-cpu/lib" "/usr/local/lib/onnxruntime-genai/lib"
write_conf /etc/ld.so.conf.d/litert.conf "/usr/local/lib"

if [ "${ENABLE_NVIDIA:-false}" = "true" ]; then
  write_conf /etc/ld.so.conf.d/cuda.conf "${CUDA_HOME:-/usr/local/cuda}/lib64"
  write_conf /etc/ld.so.conf.d/tensorrt.conf "${TENSORRT_HOME:-/usr/local/tensorrt}/lib"
elif [ "${ENABLE_AMD:-false}" = "true" ]; then
  write_conf /etc/ld.so.conf.d/rocm.conf "/opt/rocm/lib" "/opt/rocm/lib64"
fi

ldconfig
