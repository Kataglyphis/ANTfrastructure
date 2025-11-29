#!/bin/bash
set -euo pipefail

GSTREAMER_PREFIX="${GSTREAMER_PREFIX:-/opt/gstreamer}"

_arch="$(uname -m)"
case "${_arch}" in
  x86_64)
    MULTIARCH_DIR="lib/x86_64-linux-gnu"
    SYSTEM_LIB="/usr/lib/x86_64-linux-gnu"
    ;;
  aarch64|arm64)
    MULTIARCH_DIR="lib/aarch64-linux-gnu"
    SYSTEM_LIB="/usr/lib/aarch64-linux-gnu"
    ;;
  i386|i486|i586|i686)
    MULTIARCH_DIR="lib/i386-linux-gnu"
    SYSTEM_LIB="/usr/lib/i386-linux-gnu"
    ;;
  riscv64)
    MULTIARCH_DIR="lib/riscv64-linux-gnu"
    SYSTEM_LIB="/usr/lib/riscv64-linux-gnu"
    ;;
  *)
    TRIPLET="$(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || echo 'unknown')"
    if [ "$TRIPLET" != "unknown" ]; then
      MULTIARCH_DIR="lib/${TRIPLET}"
      SYSTEM_LIB="/usr/lib/${TRIPLET}"
    else
      MULTIARCH_DIR="lib/multiarch"
      SYSTEM_LIB="/usr/lib"
    fi
    ;;
esac

export PATH="${GSTREAMER_PREFIX}/bin:${PATH}"
export PKG_CONFIG_PATH="${SYSTEM_LIB}/pkgconfig:${GSTREAMER_PREFIX}/${MULTIARCH_DIR}/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="${SYSTEM_LIB}:${GSTREAMER_PREFIX}/${MULTIARCH_DIR}:${LD_LIBRARY_PATH:-}"
export GST_PLUGIN_PATH="${GSTREAMER_PREFIX}/${MULTIARCH_DIR}/gstreamer-1.0:${GST_PLUGIN_PATH:-}"
export GI_TYPELIB_PATH="${GSTREAMER_PREFIX}/${MULTIARCH_DIR}/girepository-1.0:${GI_TYPELIB_PATH:-}"

exec "$@"
