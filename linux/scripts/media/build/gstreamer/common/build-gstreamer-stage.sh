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
    echo "  gstreamer_version  Required (e.g. 1.29.1)"
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
if [ "${BUILD_MODE:-native}" = "cross" ]; then
  if command -v fix_libstdcxx_symlink >/dev/null 2>&1; then
    fix_libstdcxx_symlink || true
  fi
fi

cd /opt
bash /opt/scripts/media/build/gstreamer/common/pre-setup.sh
bash /opt/scripts/media/build/gstreamer/common/install-vvdec.sh

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

append_flag_if_missing MESON_ARGS "-Dgst-plugins-rs:skia=disabled"

set +e
bash /opt/scripts/media/build/gstreamer/common/setup-gstreamer.sh \
  "${GSTREAMER_VERSION}" \
  "${GSTREAMER_PREFIX}" \
  "${BUILD_TYPE}" 2>&1
rc=$?
set -e
if [ ${rc} -ne 0 ]; then
  echo "ERROR: GStreamer build failed (rc=${rc})" >&2
  for _log in /tmp/meson-compile.log /tmp/meson-setup.log /tmp/gst-install.log /tmp/gstreamer-cairo-debug.txt; do
    [ -f "${_log}" ] && echo "=== ${_log} ===" >&2 && cat "${_log}" >&2
  done
fi
exit ${rc}
