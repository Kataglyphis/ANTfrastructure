#!/usr/bin/env bash
# Media build bootstrap. Usage: source this file, then media_common_init "${SCRIPT_DIR}".

set -euo pipefail

# The container's /opt/scripts/core first, else an upward walk for the repo's 01-core.
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

# See docs/cross-build-verification.md
media_load_arch_flags() {
  local arch="amd64" candidate flags_file=""

  if command -v cross_build_is_active >/dev/null 2>&1 && cross_build_is_active && \
     command -v cross_target_arch >/dev/null 2>&1; then
    arch="$(cross_target_arch 2>/dev/null || echo amd64)"
  fi

  # Container layout first, then this file's own dir.
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

  # Without SCRIPTS_ROOT, modules.sh mistakes 03-media/ for the scripts root because 03-media/core/ exists.
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
  # `|| true` tolerates a module's benign last rc, so assert its functions exist instead.
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
  # Rust sccache stays opt-in until a green cross-arch media run; stats go to stderr, which buildkit never clips.
  if [ "${ENABLE_SCCACHE_RUST:-0}" = "1" ]; then
    if declare -F setup_sccache >/dev/null 2>&1; then
      setup_sccache || true
      # grep, not head: the stats output varies in length.
      { sccache --show-stats 2>/dev/null | grep -E '^(Compile requests|Cache hits|Cache misses|Non-cacheable|Unsupported|Errors)' || true; } >&2
    fi
  fi
  source_module compiler-resolution.sh || true
  source_module python-host.sh       || true
  source_module cmake-cache-linker.sh || true
  source_module abseil-headers.sh    || true

  media_load_arch_flags

  # Stats at exit: setup_ccache's own snapshot prints before the first object.
  if command -v dump_compiler_cache_stats >/dev/null 2>&1; then
    trap 'dump_compiler_cache_stats || true' EXIT
  fi
}

# install-deps.sh bootstrap. Usage: source this file, then media_install_deps_init "${SCRIPT_DIR}".
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

# media_jobs [cap_mb]: job count under a per-job memory cap (default 2000 MB).
media_jobs() {
  if declare -F compute_jobs_with_mem_cap >/dev/null 2>&1; then
    compute_jobs_with_mem_cap "" "${1:-2000}"
  else
    nproc
  fi
}

# Takes an out-var name, not $( ): it must export the sccache address into the caller's shell.
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
