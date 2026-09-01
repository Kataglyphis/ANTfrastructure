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
  local base="/opt/gstreamer/lib" cand libdir
  for cand in "${base}/${triplet}/pkgconfig/gstreamer-1.0.pc" \
              "${base}"/*/pkgconfig/gstreamer-1.0.pc \
              "${base}/pkgconfig/gstreamer-1.0.pc"; do
    [ -f "${cand}" ] || continue
    libdir="$(dirname "$(dirname "${cand}")")"
    # NEVER resolve to the multiarch symlink itself. configure-runtime runs a
    # SECOND time in the package stage on a media payload that already carries
    # lib/multiarch, and the middle glob matches lib/multiarch/pkgconfig/… —
    # resolving to it would re-point multiarch at ITSELF (a self-referential
    # link that dangles). Skip it; we want the real triplet/lib dir. (Belt-and-
    # suspenders: the caller also rm's the stale link before calling us.)
    [ "${libdir}" = "${base}/multiarch" ] && continue
    printf '%s' "${libdir}"   # the libdir that carries pkgconfig/
    return 0
  done
  # Nothing built yet / unexpected layout: keep the historical default so a
  # later repair or the package-lane dev-surface gate can still act.
  printf '%s' "${base}/${triplet}"
}

# Drop any pre-existing multiarch symlink BEFORE resolving, so (a) the resolver
# can't self-match it and (b) we always recreate it fresh from the real
# pc-carrying dir. It is ALWAYS a symlink here (never a real dir), so removing
# it drops only the link, never the target.
if [ -L /opt/gstreamer/lib/multiarch ]; then rm -f /opt/gstreamer/lib/multiarch; fi

gst_libdir="$(resolve_gstreamer_libdir)"
mkdir -p "${gst_libdir}"
ln -snf "${gst_libdir}" "/opt/gstreamer/lib/multiarch" || true

# GST1 check — WARN only, NOT fail-loud. This runs in the package stage BEFORE
# repair_gstreamer_multiarch_link (setup-package-image.sh), which fixes any
# residual dangle, and the pkg-config `verify_consumer_dev_surface` gate right
# after is the fail-loud authority. (An earlier fail-loud exit HERE killed the
# riscv64 build before the repair net could act — 2026-08-16.)
if find /opt/gstreamer/lib -name gstreamer-1.0.pc -type f 2>/dev/null | grep -q .; then
  if [ ! -f /opt/gstreamer/lib/multiarch/pkgconfig/gstreamer-1.0.pc ]; then
    echo "WARN: gstreamer-1.0.pc under /opt/gstreamer/lib does not yet resolve via" >&2
    echo "      lib/multiarch/pkgconfig (multiarch -> $(readlink /opt/gstreamer/lib/multiarch 2>/dev/null || echo '?')) —" >&2
    echo "      repair_gstreamer_multiarch_link + the dev-surface gate will handle it." >&2
  else
    echo "OK: gstreamer dev surface resolves via lib/multiarch/pkgconfig/gstreamer-1.0.pc"
  fi
fi

# ld.so: register the resolved libdir AND the plain lib/ root (cross libdir=lib
# puts the .so there) so the runtime linker finds gstreamer on every layout.
# 000- prefix: ld.so.conf.d is read in SORT order, and the distro packages
# (pulled back in by the gtk4 chain) export the SAME sonames. Without it the
# multiarch dir wins and a consumer links distro 1.28.2 against our 1.29.2
# plugins. docs/cross-build-verification.md
write_conf /etc/ld.so.conf.d/000-gstreamer.conf "${gst_libdir}" "/opt/gstreamer/lib"
write_conf /etc/ld.so.conf.d/000-libcamera.conf "/opt/libcamera/lib" "/opt/libcamera/lib64"
write_conf /etc/ld.so.conf.d/000-ffmpeg.conf "/opt/ffmpeg/lib"
write_conf /etc/ld.so.conf.d/000-opencv.conf "/opt/opencv5/lib"
write_conf /etc/ld.so.conf.d/000-armnn.conf "/opt/armnn/lib" "/opt/acl/lib"
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
