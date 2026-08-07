#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../../core/common.sh"
media_common_init "${SCRIPT_DIR}"

case "${1:-}" in
  -h|--help)
    echo "Usage: $0 <gstreamer_version> [prefix] [build_type]"
    echo ""
    echo "Build GStreamer from the monorepo source with all plugins."
    echo ""
    echo "Arguments:"
    echo "  gstreamer_version  Required (e.g. 1.29.2)"
    echo "  prefix             Install prefix (default: /opt/gstreamer)"
    echo "  build_type         Release | Debug (default: Release)"
    echo ""
    echo "Environment:"
    echo "  BUILD_MODE=cross   Enable cross-compile flags"
    echo "  TARGET_ARCH        Target architecture (amd64/arm64/riscv64)"
    exit 0
    ;;
esac

GSTREAMER_VERSION="${1:?gstreamer version is required}"
GSTREAMER_PREFIX="${2:-/opt/gstreamer}"
BUILD_TYPE="${3:-Release}"

# Disable Python bindings for cross builds targeting foreign arches.
# setup-gstreamer.sh and build-gstreamer-monorepo.sh also check
# cross_target_python_dev_ready and arch-specific patterns, but those
# are finer-grained checks that may not cover all edge cases (e.g.
# arm64 with staged Python that still fails GIR generation).
# This early override ensures consistent behavior regardless of the
# downstream script's own detection logic.
if [ "${BUILD_MODE:-native}" = "cross" ] && [ "${TARGET_ARCH:-${TARGETARCH:-amd64}}" != "amd64" ]; then
  export GSTREAMER_ENABLE_PYTHON_BINDINGS=false
fi

ensure_gstreamer_multiarch_layout() {
  local triplet
  triplet="$(arch_deb_multiarch_triplet_for "${TARGET_ARCH:-${TARGETARCH:-amd64}}")" || true
  if [ -z "${triplet}" ]; then
    triplet="$(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true)"
  fi
  [ -n "${triplet}" ] || return 0
  mkdir -p "${GSTREAMER_PREFIX}/lib/${triplet}"
  ln -snf "${GSTREAMER_PREFIX}/lib/${triplet}" "${GSTREAMER_PREFIX}/lib/multiarch" || true
}

ensure_gstreamer_multiarch_layout

# Ensure CC/CXX are exported for cross-compilation. setup_linux_cross_env may
# fail to export CXX. Use canonical helper from compiler-resolution.sh.
if [ "${BUILD_MODE:-native}" = "cross" ] && { [ -z "${CC:-}" ] || [ -z "${CXX:-}" ]; }; then
  if command -v resolve_cross_cc_cxx_for_arch >/dev/null 2>&1; then
    resolve_cross_cc_cxx_for_arch || true
  fi
fi
# Fix broken libstdc++.so symlinks that point to wrong-arch libraries.
# The SDK image's apt packages may create symlinks in /usr/lib/<triplet>/
# that point to the host (amd64) libstdc++ instead of the target arch one.
if [ "${BUILD_MODE:-native}" = "cross" ] && [ "${TARGET_ARCH:-${TARGETARCH:-}}" != "amd64" ]; then
  if command -v fix_libstdcxx_symlink >/dev/null 2>&1; then
    fix_libstdcxx_symlink || true
  else
    # Inline fallback when compiler-resolution.sh doesn't have the helper
    # (older SDK images). Uses arch_deb_multiarch_triplet_for if available.
    _fix_arch="${TARGET_ARCH:-${TARGETARCH:-}}"
    _fix_triplet=""
    if command -v arch_deb_multiarch_triplet_for >/dev/null 2>&1; then
      _fix_triplet="$(arch_deb_multiarch_triplet_for "${_fix_arch}" 2>/dev/null || true)"
    else
      case "${_fix_arch}" in
        amd64)   _fix_triplet="x86_64-linux-gnu" ;;
        arm64)   _fix_triplet="aarch64-linux-gnu" ;;
        riscv64) _fix_triplet="riscv64-linux-gnu" ;;
      esac
    fi
    if [ -n "${_fix_triplet}" ] && [ -L "/usr/lib/${_fix_triplet}/libstdc++.so" ]; then
      _gcc_lib="/opt/gcc-${GCC_VERSION:-16.2.0}/${_fix_triplet}/lib64/libstdc++.so"
      if [ -f "${_gcc_lib}" ]; then
        ln -sf "${_gcc_lib}" "/usr/lib/${_fix_triplet}/libstdc++.so"
      fi
    fi
  fi
fi

# The fix above only repoints the libstdc++.so DEV symlink and only for a
# wrong-ARCH target. But the onnx/onnxruntime plugin link resolves the RUNTIME
# libstdc++.so.6 (via -rpath-link /usr/lib/<triplet>), and on cross that lib is
# either the host-arch GCC copy or the older Ubuntu Ports libstdc++ — both lack
# GLIBCXX_3.4.35 / std::__format that libonnxruntime.so (built with GCC 16)
# needs, causing "undefined reference" link failures that abort the GStreamer
# build. Pin BOTH the dev and runtime target-arch libstdc++ to GCC 16's
# target-arch build (a backward-compatible superset).
if [ "${BUILD_MODE:-native}" = "cross" ] && [ "${TARGET_ARCH:-${TARGETARCH:-}}" != "amd64" ]; then
  if command -v pin_target_libstdcxx >/dev/null 2>&1; then
    pin_target_libstdcxx "${TARGET_ARCH:-${TARGETARCH:-}}" || true
  fi
fi

cd /opt
bash /opt/scripts/03-media/build/gstreamer/common/pre-setup.sh
bash /opt/scripts/03-media/build/gstreamer/common/install-vvdec.sh
# Provide the system rice-proto C library so gst-plugins-rs webrtcbin2 can build
# (best-effort; only runs when GST_RS_BUILD_ALL=true). Must precede meson setup
# so dependency('rice-proto') resolves.
bash /opt/scripts/03-media/build/gstreamer/common/install-rice-proto.sh

export SODIUM_USE_PKG_CONFIG=1
export PKG_CONFIG_ALLOW_CROSS=1
export PKG_CONFIG_SYSROOT_DIR="${PKG_CONFIG_SYSROOT_DIR:-/}"

triplet="$(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true)"
if [ -n "${triplet}" ]; then
  export PKG_CONFIG_LIBDIR="/usr/lib/${triplet}/pkgconfig:/usr/lib/pkgconfig:/usr/local/lib/pkgconfig${PKG_CONFIG_LIBDIR:+:${PKG_CONFIG_LIBDIR}}"
else
  export PKG_CONFIG_LIBDIR="/usr/lib/pkgconfig:/usr/local/lib/pkgconfig${PKG_CONFIG_LIBDIR:+:${PKG_CONFIG_LIBDIR}}"
fi

export SODIUM_SHARED=1
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"

# skia is built when GST_RS_BUILD_ALL=true (default); skia-safe compiles Skia
# from source where no prebuilt exists. Force it off only when build-all is off.
[ "${GST_RS_BUILD_ALL:-true}" = "true" ] || append_flag_if_missing MESON_ARGS "-Dgst-plugins-rs:skia=disabled"

# Dump diagnostic logs on GStreamer build failure, then propagate the exit code.
# This replaces the previous set +e / set -e pattern, keeping errexit active
# throughout the script so intermediate command failures are not masked.
_dump_gst_build_logs() {
  local _log
  echo "=== GStreamer build failed — dumping diagnostic logs ===" >&2
  for _log in /tmp/meson-compile.log /tmp/meson-setup.log /tmp/gst-install.log /tmp/gstreamer-cairo-debug.txt; do
    [ -f "${_log}" ] && echo "--- ${_log} ---" >&2 && cat "${_log}" >&2
  done
}
trap '_dump_gst_build_logs' ERR

bash /opt/scripts/03-media/build/gstreamer/common/setup-gstreamer.sh \
  "${GSTREAMER_VERSION}" \
  "${GSTREAMER_PREFIX}" \
  "${BUILD_TYPE}" 2>&1

trap - ERR
