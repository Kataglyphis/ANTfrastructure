#!/usr/bin/env bash
set -euo pipefail

GSTREAMER_VERSION="${1:?gstreamer version is required}"
GSTREAMER_PREFIX="${2:-/opt/gstreamer}"
BUILD_TYPE="${3:-Release}"

ensure_gstreamer_multiarch_layout() {
  local target_arch="${TARGET_ARCH:-${TARGETARCH:-}}"
  local triplet=""

  case "${target_arch}" in
    amd64) triplet="x86_64-linux-gnu" ;;
    arm64) triplet="aarch64-linux-gnu" ;;
    riscv64) triplet="riscv64-linux-gnu" ;;
    *) triplet="$(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true)" ;;
  esac

  [ -n "${triplet}" ] || return 0
  mkdir -p "${GSTREAMER_PREFIX}/lib/${triplet}"
  ln -snf "${GSTREAMER_PREFIX}/lib/${triplet}" "${GSTREAMER_PREFIX}/lib/multiarch" || true
}

append_meson_arg_if_missing() {
  local arg="$1"

  case " ${MESON_ARGS:-} " in
    *" ${arg} "*) return 0 ;;
  esac

  export MESON_ARGS="${MESON_ARGS:+${MESON_ARGS} }${arg}"
}

ensure_gstreamer_multiarch_layout

cd /opt
bash /opt/scripts/media/gstreamer/common/pre-setup.sh
/opt/scripts/media/gstreamer/common/install-vvdec.sh

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

append_meson_arg_if_missing "-Dgst-plugins-rs:skia=disabled"

bash /opt/scripts/media/gstreamer/common/setup-gstreamer.sh \
  "${GSTREAMER_VERSION}" \
  "${GSTREAMER_PREFIX}" \
  "${BUILD_TYPE}"
