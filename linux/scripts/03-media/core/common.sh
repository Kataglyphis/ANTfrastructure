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

# Why the media bootstrap resolves its module dir this way:
# docs/cross-build-verification.md
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
  source_module guard-helpers.sh     || true
  source_module parallelism.sh       || true
  # The `|| true` above tolerates a benign rc from a module's last statement, so
  # assert the OUTCOME instead: a critical module that did not load leaves its
  # functions undefined. docs/failure-modes.md
  local _fn _missing=""
  for _fn in log cross_build_is_active mem_capped_jobs; do
    declare -F "${_fn}" >/dev/null 2>&1 || _missing="${_missing} ${_fn}"
  done
  if [ -n "${_missing}" ]; then
    echo "ERROR: media_common_init: critical module(s) did not load -- missing:${_missing}" >&2
    return 1
  fi

  # Optional modules — may not be needed by every consumer.
  source_module cross-meson.sh       || true
  source_module cross-apt.sh         || true
  source_module downloads.sh         || true
  source_module compiler-cache.sh    && { setup_ccache; setup_lld_linker; } || true
  source_module qnn-sdk.sh           || true
  # Rust compile caching (sccache) — GATED, default OFF. setup_sccache's own
  # doc says "sccache for Rust, ccache for C/C++ is the recommended setup",
  # but it was never invoked here, and Dockerfile.toolchain defensively clears
  # RUSTC_WRAPPER for cross builds (bf1fb22, 2026-05-10, reason undocumented).
  # ENABLE_SCCACHE_RUST=1 activates the wiring for a CONTROLLED validation
  # build; flip the Dockerfile.media default only after a green cross-arch
  # media run. Ordering matters: setup_ccache above already owns the CMAKE
  # launchers, so setup_sccache's launcher fallback stays inert (by design).
  # Stats go to STDERR — the stream buildkit's 2MiB step-log clip never cuts.
  if [ "${ENABLE_SCCACHE_RUST:-0}" = "1" ]; then
    if declare -F setup_sccache >/dev/null 2>&1; then
      setup_sccache || true
      # LOG19: grep -E selects the lines that matter instead of head -6,
      # which cuts off Non-cacheable/Unsupported on variable-length output.
      { sccache --show-stats 2>/dev/null | grep -E '^(Compile requests|Cache hits|Cache misses|Non-cacheable|Unsupported|Errors)' || true; } >&2
    fi
  fi
  source_module compiler-resolution.sh || true
  source_module python-host.sh       || true
  source_module cmake-cache-linker.sh || true
  source_module abseil-headers.sh    || true

  # Load the data-driven per-arch MEDIA_SKIP_* flags now that the cross-env
  # helpers are available.
  media_load_arch_flags

  # LOG19: Dump compiler cache stats on script exit — the setup-time snapshot
  # in setup_ccache prints before the first object, so it always shows 0 requests.
  # This EXIT trap fires after the build completes, reflecting real activity.
  # Safe under set -e: the trap command list ends with `|| true`.
  if command -v dump_compiler_cache_stats >/dev/null 2>&1; then
    trap 'dump_compiler_cache_stats || true' EXIT
  fi
}

# Bootstrap entry point for install-deps.sh scripts ---------------------------
#
# Replaces the ~9-line install-deps-preamble.sh source-loop (and, for
# gstreamer, the extra core/common.sh load + media_load_arch_flags) that was
# copy-pasted into every media install-deps.sh. Callers source THIS file
# (03-media/core/common.sh, via the fixed ../../core relative path that is
# identical in the container and repo layouts) and then invoke this.
#
# It sources the shared 01-core install-deps-preamble.sh (which itself locates
# and loads cross-env.sh — providing is_cross / install_target_packages /
# host_python_major_minor / ...), trying the in-container path first and the
# repo layout second, then loads the data-driven per-arch MEDIA_SKIP_* flags.
#
# Usage (top of any install-deps.sh):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/../../core/common.sh"
#   media_install_deps_init "${SCRIPT_DIR}"
media_install_deps_init() {
  local script_dir="${1:-$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)}"
  local _dep_env
  for _dep_env in \
      "/opt/scripts/core/install-deps-preamble.sh" \
      "${script_dir}/../../../01-core/install-deps-preamble.sh"; do
    if [ -f "${_dep_env}" ]; then
      # shellcheck disable=SC1090
      source "${_dep_env}" || { echo "FATAL: cannot load ${_dep_env}" >&2; exit 1; }
      break
    fi
  done

  media_load_arch_flags
}

# Parallel job-count helper --------------------------------------------------
#
# Consolidates the copy-pasted "compute_jobs_with_mem_cap else nproc" ladder
# (2000-MB per-job memory cap) used across the media build scripts. The
# canonical compute_jobs_with_mem_cap lives in 01-core/parallelism.sh and is
# loaded by media_common_init; fall back to plain nproc if it is unavailable.
media_jobs() {
  if declare -F compute_jobs_with_mem_cap >/dev/null 2>&1; then
    compute_jobs_with_mem_cap "" 2000
  else
    nproc
  fi
}

# Compile-cache launcher helper ----------------------------------------------
#
# The one owner of "establish the launcher address, resolve a launcher, fall
# back to ccache" for the media scripts that prefix a compiler with it. Takes an
# out-variable NAME and prints nothing: it exports the sccache server address
# into the caller's shell, which a $( ) subshell cannot do.
# docs/cross-build-verification.md#the-media-compile-cache-launcher
media_compiler_launcher() {
  local -n _mcl_launcher="$1"
  _mcl_launcher=""
  if declare -F compiler_cache_launcher >/dev/null 2>&1; then
    compiler_cache_launcher_env 2>/dev/null || true
    _mcl_launcher="$(compiler_cache_launcher 2>/dev/null || true)"
    return 0
  fi
  if command -v ccache >/dev/null 2>&1 && is_truthy "${USE_CCACHE:-true}"; then
    _mcl_launcher="ccache"
  fi
  return 0
}
