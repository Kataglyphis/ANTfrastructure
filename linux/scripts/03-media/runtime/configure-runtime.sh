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

# The libdir that really carries gstreamer-1.0.pc: native meson uses lib/<triplet>, cross builds lib/.
resolve_gstreamer_libdir() {
  local base="/opt/gstreamer/lib" cand libdir
  for cand in "${base}/${triplet}/pkgconfig/gstreamer-1.0.pc" \
              "${base}"/*/pkgconfig/gstreamer-1.0.pc \
              "${base}/pkgconfig/gstreamer-1.0.pc"; do
    [ -f "${cand}" ] || continue
    libdir="$(dirname "$(dirname "${cand}")")"
    # Never the multiarch link itself: the package stage reruns this on a payload that has one.
    [ "${libdir}" = "${base}/multiarch" ] && continue
    printf '%s' "${libdir}"   # the libdir that carries pkgconfig/
    return 0
  done
  # Nothing found: keep the default so the later repair or the dev-surface gate can act.
  printf '%s' "${base}/${triplet}"
}

# Drop the old link before resolving so the resolver cannot match it.
if [ -L /opt/gstreamer/lib/multiarch ]; then rm -f /opt/gstreamer/lib/multiarch; fi

gst_libdir="$(resolve_gstreamer_libdir)"
mkdir -p "${gst_libdir}"
ln -snf "${gst_libdir}" "/opt/gstreamer/lib/multiarch" || true

# Warn only: repair_gstreamer_multiarch_link runs later and verify_consumer_dev_surface is the hard gate.
if find /opt/gstreamer/lib -name gstreamer-1.0.pc -type f 2>/dev/null | grep -q .; then
  if [ ! -f /opt/gstreamer/lib/multiarch/pkgconfig/gstreamer-1.0.pc ]; then
    echo "WARN: gstreamer-1.0.pc under /opt/gstreamer/lib does not yet resolve via" >&2
    echo "      lib/multiarch/pkgconfig (multiarch -> $(readlink /opt/gstreamer/lib/multiarch 2>/dev/null || echo '?')) —" >&2
    echo "      repair_gstreamer_multiarch_link + the dev-surface gate will handle it." >&2
  else
    echo "OK: gstreamer dev surface resolves via lib/multiarch/pkgconfig/gstreamer-1.0.pc"
  fi
fi

# 000-: ld.so.conf.d is read in sort order and distro packages ship the same sonames. See docs/cross-build-verification.md
write_conf /etc/ld.so.conf.d/000-gstreamer.conf "${gst_libdir}" "/opt/gstreamer/lib"
write_conf /etc/ld.so.conf.d/000-libcamera.conf "/opt/libcamera/lib" "/opt/libcamera/lib64"
write_conf /etc/ld.so.conf.d/000-ffmpeg.conf "/opt/ffmpeg/lib"
write_conf /etc/ld.so.conf.d/000-opencv.conf "/opt/opencv5/lib"
write_conf /etc/ld.so.conf.d/000-armnn.conf "/opt/armnn/lib" "/opt/acl/lib"
# 000- like the rest: the chain ORT is ours too, and sorts ahead of /opt/opencv5's forwarding links.
rm -f /etc/ld.so.conf.d/onnxruntime.conf
write_conf /etc/ld.so.conf.d/000-onnxruntime.conf "/usr/local/lib/onnxruntime-cpu/lib" "/usr/local/lib/onnxruntime-genai/lib"
write_conf /etc/ld.so.conf.d/litert.conf "/usr/local/lib"
write_conf /etc/ld.so.conf.d/gcc.conf "/opt/gcc-${GCC_VERSION:-16.2.0}/lib64" "/opt/gcc-${GCC_VERSION:-16.2.0}/lib"

if [ "${ENABLE_NVIDIA:-false}" = "true" ]; then
  write_conf /etc/ld.so.conf.d/cuda.conf "${CUDA_HOME:-/usr/local/cuda}/lib64"
  write_conf /etc/ld.so.conf.d/tensorrt.conf "${TENSORRT_HOME:-/usr/local/tensorrt}/lib"
elif [ "${ENABLE_AMD:-false}" = "true" ]; then
  write_conf /etc/ld.so.conf.d/migraphx.conf "/opt/rocm/lib" "/opt/rocm/lib64"
fi

ldconfig

# Owner rule 2026-09-23: the chain is the only ONNX Runtime -- no apt copy, no stray file on a loader path.
# shellcheck source=ort-runtime-gate.sh
source "$(dirname "${BASH_SOURCE[0]}")/ort-runtime-gate.sh"
ort_runtime_gate "/usr/local/lib/onnxruntime-cpu/lib:/usr/local/lib/onnxruntime-gpu/lib"
