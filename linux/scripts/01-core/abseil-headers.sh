#!/usr/bin/env bash
[ -n "${_ABSEIL_HEADERS_SH_LOADED:-}" ] && return 0
_ABSEIL_HEADERS_SH_LOADED=1

# Defensive loggers (real definitions live in logging.sh via artifact-common.sh
# / common.sh module chain). If sourced standalone we still need to log.
if ! command -v info >/dev/null 2>&1; then
  info() { printf '[INFO] %s\n' "$*"; }
fi
if ! command -v warn >/dev/null 2>&1; then
  warn() { printf '[WARN] %s\n' "$*" >&2; }
fi

# install_abseil_headers — fetch and extract the abseil-cpp public headers so
# downstream consumers of tflite/interpreter.h can resolve absl/types/span.h.
#
# This is the single canonical implementation of "Critical Fix #2" (see
# verify-critical-fixes.sh). It replaces the previously duplicated blocks in
# build-litert.sh and build-libcamera.sh so both installs share the same robust
# extraction fallback chain.
#
# Usage:  install_abseil_headers <dest_include_dir> [abseil_tag]
# Env:    ABSEIL_VERSION  (default 20240722.0)
# Idempotent: skips when <dest_include_dir>/absl/types/span.h already exists.
# Returns: 0 on success (or skip), 1 on hard failure (caller decides to err/warn).
install_abseil_headers() {
  local dest_dir="${1:-/usr/local/include}"
  local absl_tag="${2:-${ABSEIL_VERSION:-20240722.0}}"
  local absl_url="https://github.com/abseil/abseil-cpp/archive/refs/tags/${absl_tag}.tar.gz"
  local absl_tar="/tmp/abseil-${absl_tag}-$$.tar.gz"
  local marker="${dest_dir}/absl/types/span.h"

  if [ -f "${marker}" ]; then
    info "abseil headers already present at ${dest_dir}/absl/ (span.h found)"
    return 0
  fi

  info "Downloading abseil-cpp headers (tag ${absl_tag}) to ${dest_dir}/absl/ ..."

  # Stage the tarball via curl or wget.
  local absl_tar_resolved=""
  if command -v curl >/dev/null 2>&1; then
    if curl -fSL --retry 3 "${absl_url}" -o "${absl_tar}" 2>/dev/null; then
      absl_tar_resolved="${absl_tar}"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if wget --retry-connrefused --timeout=30 -O "${absl_tar}" "${absl_url}" 2>/dev/null; then
      absl_tar_resolved="${absl_tar}"
    fi
  fi

  if [ -z "${absl_tar_resolved}" ] || [ ! -f "${absl_tar}" ]; then
    warn "Failed to download abseil-cpp headers from ${absl_url}"
    return 1
  fi

  mkdir -p "${dest_dir}/absl"

  # Primary extraction path: GNU tar with wildcards. Falls back to a manifest
  # extract for tar builds without wildcards, then to a manual find/copy.
  if ! tar -xzf "${absl_tar}" -C "${dest_dir}" --strip-components=1 \
        --wildcards '*/absl/*.h' '*/absl/**/*.h' 2>/dev/null; then
    if ! tar -xzf "${absl_tar}" -C "${dest_dir}" --strip-components=1 --no-wildcards \
          --files-from <(tar -tzf "${absl_tar}" | grep '/absl/.*\.h$' 2>/dev/null) 2>/dev/null; then
      # Last-resort fallback: extract everything, then copy headers manually.
      local absl_tmp="/tmp/abseil-extract-$$"
      mkdir -p "${absl_tmp}"
      tar -xzf "${absl_tar}" -C "${absl_tmp}" 2>/dev/null || true
      local absl_src
      absl_src="$(find "${absl_tmp}" -maxdepth 2 -type d -name "abseil-cpp*" -print -quit 2>/dev/null || true)"
      if [ -n "${absl_src}" ] && [ -d "${absl_src}/absl" ]; then
        info "Falling back to manual copy from ${absl_src}/absl ..."
        find "${absl_src}/absl" -type f \( -name "*.h" -o -name "*.inc" \) \
          -exec cp --parents "{}" "${dest_dir}/" \; 2>/dev/null || true
      fi
      rm -rf "${absl_tmp}"
    fi
  fi

  rm -f "${absl_tar}"

  if [ -f "${marker}" ]; then
    info "abseil headers installed (span.h verified at ${marker})"
    return 0
  fi

  warn "abseil-cpp headers extraction did not yield ${marker}"
  return 1
}