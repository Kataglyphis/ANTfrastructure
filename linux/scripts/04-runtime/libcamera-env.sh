#!/usr/bin/env bash
set -euo pipefail
# Usage: source libcamera-env.sh [prefix]  (default $LIBCAMERA_PREFIX, else /opt/libcamera)

# Sourced, $1 may be the caller's own argument; ignore it when it is this script's path.
if [ -n "${BASH_SOURCE:-}" ] && [ "${BASH_SOURCE[0]}" != "$0" ]; then
  # Being sourced
  if [ $# -ge 1 ]; then
    case "$1" in
      */libcamera-env.sh|libcamera-env.sh)
        LIBCAMERA_PREFIX="${LIBCAMERA_PREFIX:-/opt/libcamera}"
        ;;
      *)
        LIBCAMERA_PREFIX="$1"
        ;;
    esac
  else
    LIBCAMERA_PREFIX="${LIBCAMERA_PREFIX:-/opt/libcamera}"
  fi
else
  # Executed as a script: accept $1 or env override, default to /opt/libcamera
  LIBCAMERA_PREFIX="${1:-${LIBCAMERA_PREFIX:-/opt/libcamera}}"
fi

# ensure we have a non-empty prefix
if [ -z "${LIBCAMERA_PREFIX}" ]; then
  echo "libcamera-env: LIBCAMERA_PREFIX is empty" >&2
  return 1 2>/dev/null || exit 1
fi

# A prefix that names this script falls back to the default install.
if [ -n "${LIBCAMERA_PREFIX}" ] && [[ "${LIBCAMERA_PREFIX}" == *libcamera-env.sh ]]; then
  LIBCAMERA_PREFIX="/opt/libcamera"
fi

# Warn if the resolved prefix does not exist (helps debugging misconfigured images)
if [ ! -d "${LIBCAMERA_PREFIX}" ]; then
  echo "libcamera-env: warning: prefix '${LIBCAMERA_PREFIX}' does not exist" >&2
fi

# Shared path helpers when shipped, else local fallbacks.
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

# Append, never prepend: a Raspberry Pi run bind-mounts the host's libcamera and names it here first.
_libcamera_path_append() {
  local __varname="$1" __value="$2" __cur
  __cur="${!__varname:-}"
  case ":${__cur}:" in *":${__value}:"*) return 0 ;; esac
  if [ -z "${__cur}" ]; then
    printf -v "${__varname}" '%s' "${__value}"
  else
    printf -v "${__varname}" '%s:%s' "${__cur}" "${__value}"
  fi
  export "${__varname?}"
}

PREFIX="$LIBCAMERA_PREFIX"

# Detect multiarch triplet if possible (for proper library paths)
MULTIARCH_TRIPLET=""

# Prefer shared helper if present (Docker image layout)
if [ -f /opt/scripts/core/platform.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/platform.sh
  MULTIARCH_TRIPLET="$(deb_multiarch_triplet)"
fi

# Fallback to system tool
if [ -z "${MULTIARCH_TRIPLET}" ] && command -v dpkg-architecture >/dev/null 2>&1; then
  MULTIARCH_TRIPLET="$(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true)"
fi

# PKG_CONFIG_PATH locations (including multiarch)
for d in \
  "${PREFIX}/lib/${MULTIARCH_TRIPLET}/pkgconfig" \
  "${PREFIX}/lib64/${MULTIARCH_TRIPLET}/pkgconfig" \
  "${PREFIX}/lib/pkgconfig" \
  "${PREFIX}/lib64/pkgconfig" \
  "${PREFIX}/share/pkgconfig" \
; do
  if [ -d "$d" ]; then
    _libcamera_path_append PKG_CONFIG_PATH "$d"
  fi
done

# Fallback: scan common nested pkgconfig dirs (e.g. lib/<triplet>/pkgconfig)
for d in "${PREFIX}/lib"/*/pkgconfig "${PREFIX}/lib"/*/*/pkgconfig; do
  [ -d "$d" ] || continue
  _libcamera_path_append PKG_CONFIG_PATH "$d"
done

# runtime library search paths (including multiarch)
for d in \
  "${PREFIX}/lib/${MULTIARCH_TRIPLET}" \
  "${PREFIX}/lib64/${MULTIARCH_TRIPLET}" \
  "${PREFIX}/lib" \
  "${PREFIX}/lib64" \
; do
  if [ -d "$d" ]; then
    _libcamera_path_append LD_LIBRARY_PATH "$d"
  fi
done

# Fallback: include nested lib directories (e.g. lib/<triplet> or lib/*/)
for d in "${PREFIX}/lib"/* "${PREFIX}/lib"/*/*; do
  [ -d "$d" ] || continue
  _libcamera_path_append LD_LIBRARY_PATH "$d"
done

# bin tools (e.g. libcamera-apps)
if [ -d "${PREFIX}/bin" ]; then
  # append to PATH if not present
  _libcamera_path_append PATH "${PREFIX}/bin"
fi

# Python site-packages, whichever python3 version built them.
for p in \
  "${PREFIX}/lib/python3*/site-packages" \
  "${PREFIX}/lib/python3*/dist-packages" \
  "${PREFIX}/lib64/python3*/site-packages" \
  "${PREFIX}/lib64/python3*/dist-packages" \
; do
  # expand glob safely
  for dir in $p; do
    [ -d "$dir" ] || continue
    _libcamera_path_append PYTHONPATH "$dir"
  done
done

# also consider pkg-installed python module locations under prefix/share
if [ -d "${PREFIX}/share/python" ]; then
  _libcamera_path_append PYTHONPATH "${PREFIX}/share/python"
fi

# GStreamer plugin path for libcamerasrc (including multiarch paths)
for p in \
  "${PREFIX}/lib/${MULTIARCH_TRIPLET}/gstreamer-1.0" \
  "${PREFIX}/lib64/${MULTIARCH_TRIPLET}/gstreamer-1.0" \
  "${PREFIX}/lib/gstreamer-1.0" \
  "${PREFIX}/lib64/gstreamer-1.0" \
; do
  if [ -d "$p" ]; then
    _libcamera_path_append GST_PLUGIN_PATH "$p"
  fi
done

# Fallback: scan nested gstreamer plugin dirs
for p in "${PREFIX}/lib"/*/gstreamer-1.0 "${PREFIX}/lib"/*/*/gstreamer-1.0; do
  [ -d "$p" ] || continue
  _libcamera_path_append GST_PLUGIN_PATH "$p"
done

# Export LIBCAMERA_PREFIX for convenience
export LIBCAMERA_PREFIX="$PREFIX"

# Optional helper to show useful info
libcamera_env_show() {
  echo "libcamera-env: LIBCAMERA_PREFIX = ${LIBCAMERA_PREFIX}"
  echo "  MULTIARCH_TRIPLET = ${MULTIARCH_TRIPLET:-<not detected>}"
  echo "  PATH = ${PATH}"
  echo "  PKG_CONFIG_PATH = ${PKG_CONFIG_PATH:-"<empty>"}"
  echo "  LD_LIBRARY_PATH = ${LD_LIBRARY_PATH:-"<empty>"}"
  echo "  GST_PLUGIN_PATH = ${GST_PLUGIN_PATH:-"<empty>"}"
  echo "  PYTHONPATH = ${PYTHONPATH:-"<empty>"}"
  if command -v pkg-config >/dev/null 2>&1; then
    if pkg-config --exists libcamera >/dev/null 2>&1; then
      echo "  pkg-config: libcamera found -> $(pkg-config --modversion libcamera 2>/dev/null || echo "<version unknown>")"
    else
      echo "  pkg-config: libcamera NOT found in current PKG_CONFIG_PATH"
    fi
  fi
  if command -v gst-inspect-1.0 >/dev/null 2>&1; then
    if gst-inspect-1.0 libcamerasrc >/dev/null 2>&1; then
      echo "  gst-inspect-1.0: libcamerasrc plugin found ✓"
    else
      echo "  gst-inspect-1.0: libcamerasrc plugin NOT found"
    fi
  fi
}

# Show a short one-line confirmation when sourced interactively
if [[ $- == *i* ]]; then
  echo "Sourced libcamera environment for prefix: ${LIBCAMERA_PREFIX}"
  echo "Run: libcamera_env_show  # to print environment details"
fi

# done – do not exit when sourced
return 0 2>/dev/null || true