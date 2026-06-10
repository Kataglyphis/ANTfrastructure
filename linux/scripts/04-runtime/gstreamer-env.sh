#!/usr/bin/env bash
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

if [ -f /opt/scripts/core/path-helpers.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/path-helpers.sh
else
  _path_contains() {
    local var="$1" cand="$2"
    [ -n "$var" ] || return 1
    case ":$var:" in
      *":${cand}:"*) return 0 ;;
      *) return 1 ;;
    esac
  }
  _path_prepend_unique() {
    local __varname="$1" __value="$2" __cur
    __cur="${!__varname:-}"
    if [ -z "$__cur" ]; then
      printf -v "${__varname}" '%s' "${__value}"
      export "${__varname}"
    else
      if _path_contains "$__cur" "$__value"; then
        return 0
      fi
      printf -v "${__varname}" '%s:%s' "${__value}" "${__cur}"
      export "${__varname}"
    fi
  }
fi

for d in \
  "${GSTREAMER_PREFIX}/share/pkgconfig" \
  "${GSTREAMER_PREFIX}/lib/pkgconfig" \
  "${GSTREAMER_PREFIX}/${MULTIARCH_DIR}/pkgconfig"
do
  _path_prepend_unique PKG_CONFIG_PATH "$d"
done

for d in \
  "${GSTREAMER_PREFIX}/lib" \
  "${GSTREAMER_PREFIX}/${MULTIARCH_DIR}"
do
  _path_prepend_unique LD_LIBRARY_PATH "$d"
done

for d in \
  "${GSTREAMER_PREFIX}/lib/gstreamer-1.0" \
  "${GSTREAMER_PREFIX}/${MULTIARCH_DIR}/gstreamer-1.0"
do
  _path_prepend_unique GST_PLUGIN_PATH "$d"
done

for d in \
  "${GSTREAMER_PREFIX}/lib/girepository-1.0" \
  "${GSTREAMER_PREFIX}/${MULTIARCH_DIR}/girepository-1.0"
do
  _path_prepend_unique GI_TYPELIB_PATH "$d"
done

# exec "$@"
