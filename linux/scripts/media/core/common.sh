#!/usr/bin/env bash
# linux/scripts/media/core/common.sh
#
# Single Source of Truth bootstrap for every media library build script.
#
# This eliminates the previously duplicated ~25-line preamble block that was
# copy-pasted into every script under the old 03-media/ tree. Each media build
# script now sources this file and calls `media_common_init`.
#
# It locates and sources the shared 01-core module framework (the actual
# reusable utilities: logging, platform, downloads, compiler-cache, etc.) via a
# robust upward search, so individual scripts no longer hard-code fragile
# relative paths like `../../01-core/modules.sh`.
#
# Usage (at the top of any media build script):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck disable=SC1091
#   source "${SCRIPT_DIR}/../core/common.sh"   # path adjusted per depth
#   media_common_init "${SCRIPT_DIR}"
#
# In the container image the same file is COPY'd to
# /opt/scripts/media/core/common.sh and 01-core lives at /opt/scripts/core/.

set -euo pipefail

# Print usage for -h/--help. Sourced files expose the helper via a function so
# callers can wire it into their own --help dispatch.
media_common_help() {
  cat <<'EOF'
media/core/common.sh — shared bootstrap for media build scripts

This file is sourced, not executed directly. It provides:

  media_common_init [script_dir]
      Locate the 01-core module framework (container or repo layout) and source
      the standard set of media build helpers: common.sh, cross-env.sh,
      logging.sh, parallelism.sh, downloads.sh, compiler-cache.sh,
      compiler-resolution.sh, python-host.sh, cmake-cache-linker.sh.

  cross_build_is_active
      Returns 0 when the current build is a cross-compile (BUILD_MODE=cross and
      target arch != build arch). Defined here as a fallback so downstream
      scripts always see it even when cross-env.sh's own guard skips reloading.

Environment consumed:
  BUILD_MODE   native | cross   (default: native)

Environment exported (via sourced 01-core modules):
  HOST_PYTHON_BIN, PYTHON_EXECUTABLE, NPROC, ccache/lld configuration, ...
EOF
}

# Resolve the shared 01-core module directory. Checks (in order):
#   1. The in-container path /opt/scripts/core (where the Dockerfile COPYs it)
#   2. An upward walk from the script dir for a `linux/scripts/01-core` or
#      `01-core` directory (repo / local-dev layout).
_media_find_core_dir() {
  local d="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

  if [ -f "/opt/scripts/core/modules.sh" ]; then
    printf '%s' "/opt/scripts/core"
    return 0
  fi

  while [ "${d}" != "/" ]; do
    if [ -d "${d}/linux/scripts/01-core" ]; then
      printf '%s' "${d}/linux/scripts/01-core"
      return 0
    fi
    if [ -d "${d}/01-core" ]; then
      printf '%s' "${d}/01-core"
      return 0
    fi
    d="$(cd "${d}/.." && pwd)"
  done
  return 1
}

# The single entry point replacing the old media_build_preamble_init().
media_common_init() {
  local script_dir="${1:-$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)}"
  local core_dir
  core_dir="$(_media_find_core_dir "${script_dir}")" || {
    echo "ERROR: could not locate 01-core module framework from ${script_dir}" >&2
    return 1
  }

  # Source the module loader (modules.sh) then the standard media helper set.
  # Set SCRIPTS_ROOT explicitly so source_modules_framework / source_module find
  # 01-core correctly. Without this, _find_scripts_root() in modules.sh would
  # misidentify media/ as the scripts root (because media/core/ exists), breaking
  # the relative module search on the host.
  case "${core_dir}" in
    */01-core) export SCRIPTS_ROOT="$(cd "${core_dir}/.." && pwd)" ;;
  esac

  # shellcheck disable=SC1090
  source "${core_dir}/modules.sh"
  source_modules_framework "${script_dir}"

  source_module common.sh            || true
  source_module cross-env.sh         || true
  source_module cross-meson.sh       || true
  source_module cross-apt.sh         || true
  source_module logging.sh           || true
  source_module build-helpers.sh     || true
  source_module parallelism.sh       || true
  source_module downloads.sh         || true
  source_module compiler-cache.sh    && { setup_ccache; setup_lld_linker; } || true
  source_module compiler-resolution.sh || true
  source_module python-host.sh       || true
  source_module cmake-cache-linker.sh || true

  # Fallback for cross_build_is_active in case cross-env.sh's reload guard
  # prevents it from being redefined. Prefer cross_build_enabled (which checks
  # both BUILD_MODE and cross-target != build-arch), then BUILD_MODE alone.
  if ! command -v cross_build_is_active >/dev/null 2>&1; then
    if command -v cross_build_enabled >/dev/null 2>&1; then
      cross_build_is_active() { cross_build_enabled; }
    else
      cross_build_is_active() { [ "${BUILD_MODE:-native}" = "cross" ]; }
    fi
  fi
}

# Backward-compatible alias for any external caller still using the old name.
media_build_preamble_init() { media_common_init "$@"; }
