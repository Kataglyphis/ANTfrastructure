#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Source shared modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for helper in \
    "/opt/scripts/core/modules.sh" \
    "${SCRIPT_DIR}/../../../01-core/modules.sh"; do
    if [ -f "${helper}" ]; then
        # shellcheck disable=SC1090
        source "${helper}"
        source_modules_framework "${SCRIPT_DIR}"
        break
    fi
done

source_module platform.sh || true
source_module common.sh || true

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

append_flag_if_missing MESON_ARGS "-Dgst-plugins-rs:skia=disabled"

bash /opt/scripts/media/gstreamer/common/setup-gstreamer.sh \
  "${GSTREAMER_VERSION}" \
  "${GSTREAMER_PREFIX}" \
  "${BUILD_TYPE}"
