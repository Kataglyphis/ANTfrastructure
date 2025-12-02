#!/usr/bin/env bash
# libcamera-env.sh — source this to make libcamera found by pkg-config, python and runtime loader
# Usage:
#   source ./libcamera-env.sh            # uses $LIBCAMERA_PREFIX or /opt/libcamera
#   source ./libcamera-env.sh /opt/libcamera-custom

# allow override by env var or one positional arg
if [ $# -ge 1 ]; then
  LIBCAMERA_PREFIX="$1"
else
  LIBCAMERA_PREFIX="${LIBCAMERA_PREFIX:-/opt/libcamera}"
fi

# ensure we have a non-empty prefix
if [ -z "${LIBCAMERA_PREFIX}" ]; then
  echo "libcamera-env: LIBCAMERA_PREFIX is empty" >&2
  return 1 2>/dev/null || exit 1
fi

# helper: check if colon-separated $1 contains entry $2
_path_contains() {
  # $1 = var value, $2 = candidate
  local var="$1" cand="$2"
  [ -n "$var" ] || return 1
  case ":$var:" in
    *":${cand}:"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Prepend value to colon-separated variable only if not present
_prepend_unique() {
  # args: varname, value
  local __varname="$1"; shift
  local __value="$1"
  # get current value
  eval "local __cur=\${$__varname:-}"
  if [ -z "$__cur" ]; then
    eval "export $__varname=\"${__value}\""
  else
    if _path_contains "$__cur" "$__value"; then
      return 0
    fi
    eval "export $__varname=\"${__value}:\${$__varname}\""
  fi
}

PREFIX="$LIBCAMERA_PREFIX"

# PKG_CONFIG_PATH locations (common)
for d in \
  "${PREFIX}/lib/pkgconfig" \
  "${PREFIX}/lib64/pkgconfig" \
  "${PREFIX}/share/pkgconfig" \
; do
  if [ -d "$d" ]; then
    _prepend_unique PKG_CONFIG_PATH "$d"
  fi
done

# runtime library search paths
for d in \
  "${PREFIX}/lib" \
  "${PREFIX}/lib64" \
; do
  if [ -d "$d" ]; then
    _prepend_unique LD_LIBRARY_PATH "$d"
  fi
done

# bin tools (e.g. libcamera-apps)
if [ -d "${PREFIX}/bin" ]; then
  # prepend to PATH if not present
  _prepend_unique PATH "${PREFIX}/bin"
fi

# Python site-packages locations (attempt a few common patterns)
# note: depends on which python3 version is used; we detect existing dirs
for p in \
  "${PREFIX}/lib/python3*/site-packages" \
  "${PREFIX}/lib/python3*/dist-packages" \
  "${PREFIX}/lib64/python3*/site-packages" \
  "${PREFIX}/lib64/python3*/dist-packages" \
; do
  # expand glob safely
  for dir in $p; do
    [ -d "$dir" ] || continue
    _prepend_unique PYTHONPATH "$dir"
  done
done

# also consider pkg-installed python module locations under prefix/share
if [ -d "${PREFIX}/share/python" ]; then
  _prepend_unique PYTHONPATH "${PREFIX}/share/python"
fi

# Export LIBCAMERA_PREFIX for convenience
export LIBCAMERA_PREFIX="$PREFIX"

# Optional helper to show useful info
libcamera_env_show() {
  echo "libcamera-env: LIBCAMERA_PREFIX = ${LIBCAMERA_PREFIX}"
  echo "  PATH = ${PATH}"
  echo "  PKG_CONFIG_PATH = ${PKG_CONFIG_PATH:-"<empty>"}"
  echo "  LD_LIBRARY_PATH = ${LD_LIBRARY_PATH:-"<empty>"}"
  echo "  PYTHONPATH = ${PYTHONPATH:-"<empty>"}"
  if command -v pkg-config >/dev/null 2>&1; then
    if pkg-config --exists libcamera >/dev/null 2>&1; then
      echo "  pkg-config: libcamera found -> $(pkg-config --modversion libcamera 2>/dev/null || echo "<version unknown>")"
    else
      echo "  pkg-config: libcamera NOT found in current PKG_CONFIG_PATH"
    fi
  fi
}

# Show a short one-line confirmation when sourced interactively
if [[ $- == *i* ]]; then
  echo "Sourced libcamera environment for prefix: ${LIBCAMERA_PREFIX}"
  echo "Run: libcamera_env_show  # to print environment details"
fi

# done — do not exit when sourced
return 0 2>/dev/null || true
