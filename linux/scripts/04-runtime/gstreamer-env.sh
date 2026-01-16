#!/bin/bash
set -euo pipefail

GSTREAMER_PREFIX="${GSTREAMER_PREFIX:-/opt/gstreamer}"

TRIPLET=""
if [ -f /opt/scripts/core/platform.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/platform.sh
  TRIPLET="$(deb_multiarch_triplet)"
fi

if [ -z "${TRIPLET}" ]; then
  TRIPLET="$(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || echo '')"
fi

if [ -n "${TRIPLET}" ]; then
  MULTIARCH_DIR="lib/${TRIPLET}"
  SYSTEM_LIB="/usr/lib/${TRIPLET}"
else
  MULTIARCH_DIR="lib/multiarch"
  SYSTEM_LIB="/usr/lib"
fi

export PATH="${GSTREAMER_PREFIX}/bin:${PATH}"
export PKG_CONFIG_PATH="${SYSTEM_LIB}/pkgconfig:${GSTREAMER_PREFIX}/${MULTIARCH_DIR}/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="${SYSTEM_LIB}:${GSTREAMER_PREFIX}/${MULTIARCH_DIR}:${LD_LIBRARY_PATH:-}"
export GST_PLUGIN_PATH="${GSTREAMER_PREFIX}/${MULTIARCH_DIR}/gstreamer-1.0:${GST_PLUGIN_PATH:-}"
export GI_TYPELIB_PATH="${GSTREAMER_PREFIX}/${MULTIARCH_DIR}/girepository-1.0:${GI_TYPELIB_PATH:-}"

# exec "$@"
