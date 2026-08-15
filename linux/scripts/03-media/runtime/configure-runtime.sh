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

# GST1 ROOT FIX (2026-08-15): point lib/multiarch at whichever libdir ACTUALLY
# carries gstreamer-1.0.pc, not blindly at lib/${triplet}. NATIVE meson installs
# to lib/${triplet}/ (Debian default) but the CROSS builds pass libdir=lib, so
# the .pc lands in lib/pkgconfig — a blind lib/${triplet} symlink dangled the
# ENTIRE dev surface (pkg-config gstreamer-1.0) on arm64/riscv64 in every shipped
# image, silently, until the Klasse-B package gate caught it. Resolving the real
# dir here ALSO makes GST_PLUGIN_PATH / GI_TYPELIB_PATH (both route through
# lib/multiarch/) correct on both layouts. repair_gstreamer_multiarch_link in
# setup-package-image.sh remains as the belt-and-suspenders net.
resolve_gstreamer_libdir() {
  local base="/opt/gstreamer/lib" cand
  for cand in "${base}/${triplet}/pkgconfig/gstreamer-1.0.pc" \
              "${base}"/*/pkgconfig/gstreamer-1.0.pc \
              "${base}/pkgconfig/gstreamer-1.0.pc"; do
    [ -f "${cand}" ] || continue
    dirname "$(dirname "${cand}")"   # the libdir that carries pkgconfig/
    return 0
  done
  # Nothing built yet / unexpected layout: keep the historical default so a
  # later repair or the package-lane dev-surface gate can still act.
  printf '%s' "${base}/${triplet}"
}

gst_libdir="$(resolve_gstreamer_libdir)"
mkdir -p "${gst_libdir}"
ln -snf "${gst_libdir}" "/opt/gstreamer/lib/multiarch" || true

# GST1 assert: when the gstreamer stack IS present, the dev surface consumers
# actually use (lib/multiarch/pkgconfig/gstreamer-1.0.pc) MUST resolve through
# the symlink just made — a dangling multiarch dir is the exact silent
# regression this fix closes. Skip cleanly for a gstreamer-less image.
if find /opt/gstreamer/lib -name gstreamer-1.0.pc -type f 2>/dev/null | grep -q .; then
  if [ ! -f /opt/gstreamer/lib/multiarch/pkgconfig/gstreamer-1.0.pc ]; then
    echo "ERROR: gstreamer-1.0.pc exists under /opt/gstreamer/lib but does NOT resolve" >&2
    echo "       through lib/multiarch/pkgconfig — the dev surface would ship dangling." >&2
    echo "       multiarch -> $(readlink /opt/gstreamer/lib/multiarch 2>/dev/null || echo '?')" >&2
    exit 1
  fi
  echo "OK: gstreamer dev surface resolves via lib/multiarch/pkgconfig/gstreamer-1.0.pc"
fi

# ld.so: register the resolved libdir AND the plain lib/ root (cross libdir=lib
# puts the .so there) so the runtime linker finds gstreamer on every layout.
write_conf /etc/ld.so.conf.d/gstreamer.conf "${gst_libdir}" "/opt/gstreamer/lib"
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
