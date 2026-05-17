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

_prepend_unique() {
  local var_name="$1"
  local dir="$2"
  local current

  [ -d "${dir}" ] || return 0
  current="${!var_name:-}"
  case ":${current}:" in
    *":${dir}:"*) return 0 ;;
  esac
  export "${var_name}=${dir}${current:+:${current}}"
}

for d in \
  "${GSTREAMER_PREFIX}/share/pkgconfig" \
  "${GSTREAMER_PREFIX}/lib/pkgconfig" \
  "${GSTREAMER_PREFIX}/${MULTIARCH_DIR}/pkgconfig"
do
  _prepend_unique PKG_CONFIG_PATH "$d"
done

for d in \
  "${GSTREAMER_PREFIX}/lib" \
  "${GSTREAMER_PREFIX}/${MULTIARCH_DIR}"
do
  _prepend_unique LD_LIBRARY_PATH "$d"
done

for d in \
  "${GSTREAMER_PREFIX}/lib/gstreamer-1.0" \
  "${GSTREAMER_PREFIX}/${MULTIARCH_DIR}/gstreamer-1.0"
do
  _prepend_unique GST_PLUGIN_PATH "$d"
done

for d in \
  "${GSTREAMER_PREFIX}/lib/girepository-1.0" \
  "${GSTREAMER_PREFIX}/${MULTIARCH_DIR}/girepository-1.0"
do
  _prepend_unique GI_TYPELIB_PATH "$d"
done

# exec "$@"
