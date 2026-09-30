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

# Decided once here: the downstream per-arch checks miss cases such as arm64 whose staged Python still fails GIR.
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

# setup_linux_cross_env may fail to export CXX.
if [ "${BUILD_MODE:-native}" = "cross" ] && { [ -z "${CC:-}" ] || [ -z "${CXX:-}" ]; }; then
  if command -v resolve_cross_cc_cxx_for_arch >/dev/null 2>&1; then
    resolve_cross_cc_cxx_for_arch || true
  fi
fi
# The SDK image's apt packages can point /usr/lib/<triplet>/libstdc++.so at the host's libstdc++.
if [ "${BUILD_MODE:-native}" = "cross" ] && [ "${TARGET_ARCH:-${TARGETARCH:-}}" != "amd64" ]; then
  if command -v fix_libstdcxx_symlink >/dev/null 2>&1; then
    fix_libstdcxx_symlink || true
  else
    # Older SDK images lack the helper.
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

# The onnx plugin link resolves the runtime libstdc++.so.6, and apt's lacks the GLIBCXX libonnxruntime needs.
if [ "${BUILD_MODE:-native}" = "cross" ] && [ "${TARGET_ARCH:-${TARGETARCH:-}}" != "amd64" ]; then
  if command -v pin_target_libstdcxx >/dev/null 2>&1; then
    pin_target_libstdcxx "${TARGET_ARCH:-${TARGETARCH:-}}" || true
  fi
fi

cd /opt
bash /opt/scripts/03-media/build/gstreamer/common/pre-setup.sh
bash /opt/scripts/03-media/build/gstreamer/common/install-vvdec.sh
# Before meson setup, so webrtcbin2's dependency('rice-proto') resolves.
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

# skia-safe compiles Skia from source where no prebuilt exists, so only build-all pays for it.
[ "${GST_RS_BUILD_ALL:-true}" = "true" ] || append_flag_if_missing MESON_ARGS "-Dgst-plugins-rs:skia=disabled"

# An ERR trap rather than set +e, so errexit stays active and no intermediate failure is masked.
_dump_gst_build_logs() {
  local _log
  echo "=== GStreamer build failed — dumping diagnostic logs ===" >&2
  for _log in /tmp/meson-compile.log /tmp/meson-setup.log /tmp/gst-install.log /tmp/gstreamer-cairo-debug.txt; do
    if [ -f "${_log}" ]; then
      echo "--- ${_log} ---" >&2
      cat "${_log}" >&2
    fi
  done
}
trap '_dump_gst_build_logs' ERR

bash /opt/scripts/03-media/build/gstreamer/common/setup-gstreamer.sh \
  "${GSTREAMER_VERSION}" \
  "${GSTREAMER_PREFIX}" \
  "${BUILD_TYPE}" 2>&1

trap - ERR

# --strip-all keeps .dynsym, so plugin loading is unaffected; MEDIA_STRIP=0 disables it.
declare -F strip_media_prefixes >/dev/null 2>&1 && strip_media_prefixes "${GSTREAMER_PREFIX}" || true
