#!/usr/bin/env bash
# linux/scripts/03-media/core/common.sh
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
# /opt/scripts/03-media/core/common.sh and 01-core lives at /opt/scripts/core/.

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

  media_load_arch_flags
      Source the per-target-arch MEDIA_SKIP_* flag file
      (arch-flags-<arch>.env, next to this file) for the effective target
      arch. Called automatically by media_common_init; preamble-based
      install-deps scripts source this file and call it directly.

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

# Data-driven per-arch skip flags --------------------------------------------
#
# The repeated boolean per-arch skip decisions in the media install/build
# scripts (e.g. "skip target Csound packages on riscv64/arm64 cross") are
# consolidated into declarative flag files next to this one:
# arch-flags-{amd64,arm64,riscv64}.env — KEY=value lines only (MEDIA_SKIP_*;
# 1 = skip, 0/unset = do not skip), with the per-flag justifications kept as
# comments in those files.
#
# media_load_arch_flags resolves the effective target arch — cross_target_arch
# when a cross build is active, otherwise the native amd64 defaults — and
# sources the matching flag file if present. A missing file simply leaves
# every MEDIA_SKIP_* flag unset (= do not skip), matching the old
# is_cross_*-style helpers which only ever skipped on active cross builds.
#
# Consumers:
#   - Scripts using media_common_init get the flags automatically (called at
#     the end of media_common_init, after cross-env.sh is loaded).
#   - install-deps-preamble based scripts source this file (container path
#     /opt/scripts/03-media/core/common.sh first, repo layout second) and call
#     media_load_arch_flags themselves; the preamble has already provided the
#     cross_build_is_active / cross_target_arch helpers by then.
media_load_arch_flags() {
  local arch="amd64" candidate flags_file=""

  if command -v cross_build_is_active >/dev/null 2>&1 && cross_build_is_active && \
     command -v cross_target_arch >/dev/null 2>&1; then
    arch="$(cross_target_arch 2>/dev/null || echo amd64)"
  fi

  # Container layout first (COPY'd into the media base stage), then the
  # directory this file lives in (repo / local-dev layout).
  for candidate in \
      "/opt/scripts/03-media/core/arch-flags-${arch}.env" \
      "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/arch-flags-${arch}.env"; do
    if [ -f "${candidate}" ]; then
      flags_file="${candidate}"
      break
    fi
  done

  # No flag file for this arch → keep the all-unset defaults (do not skip).
  [ -n "${flags_file}" ] || return 0

  # shellcheck disable=SC1090
  source "${flags_file}"
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
  # misidentify 03-media/ as the scripts root (because 03-media/core/ exists), breaking
  # the relative module search on the host.
  case "${core_dir}" in
    */01-core) export SCRIPTS_ROOT="$(cd "${core_dir}/.." && pwd)" ;;
  esac

  # shellcheck disable=SC1090
  source "${core_dir}/modules.sh"
  source_modules_framework "${script_dir}"

  # Critical modules — must load or the script cannot function.
  source_module common.sh            || true
  source_module cross-env.sh         || true
  source_module logging.sh           || true
  source_module build-helpers.sh     || true
  source_module parallelism.sh       || true

  # Optional modules — may not be needed by every consumer.
  source_module cross-meson.sh       || true
  source_module cross-apt.sh         || true
  source_module downloads.sh         || true
  source_module compiler-cache.sh    && { setup_ccache; setup_lld_linker; } || true
  source_module compiler-resolution.sh || true
  source_module python-host.sh       || true
  source_module cmake-cache-linker.sh || true
  source_module abseil-headers.sh    || true

  # Ensure cross_build_is_active is always defined. The canonical definition
  # lives in cross-env.sh (sourced above), and a fallback exists in
  # 01-core/common.sh. If neither loaded (e.g. reload guard), define here.
  if ! command -v cross_build_is_active >/dev/null 2>&1; then
    if command -v cross_build_enabled >/dev/null 2>&1; then
      cross_build_is_active() { cross_build_enabled; }
    else
      cross_build_is_active() {
        [ "${BUILD_MODE:-native}" = "cross" ] && \
        [ "${TARGET_ARCH:-${TARGETARCH:-}}" != "${BUILDARCH:-$(uname -m)}" ]
      }
    fi
  fi

  # Load the data-driven per-arch MEDIA_SKIP_* flags now that the cross-env
  # helpers are available.
  media_load_arch_flags
}
