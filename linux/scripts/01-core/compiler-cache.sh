#!/usr/bin/env bash
# Compiler-cache and lld wiring for the 03-media chain only: docs/build-cache-tiers.md#5-scc1--the-ccachesccache-hybrid

[ -n "${_COMPILER_CACHE_LOADED:-}" ] && return 0
_COMPILER_CACHE_LOADED=1

_CC_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${USE_CCACHE:=true}"
: "${USE_SCCACHE:=true}"
: "${USE_LLD:=true}"
# Owns the cache paths Dockerfile.package's ENV is pinned to: docs/build-cache-tiers.md#the-shipped-images-cache-dirs
: "${CCACHE_DIR:=/var/cache/ccache}"
: "${CCACHE_MAXSIZE:=10G}"
: "${SCCACHE_DIR:=/var/cache/sccache}"
: "${SCCACHE_CACHE_SIZE:=10G}"

_cc_info() {
  printf '[CACHE] %s\n' "$*"
}

_cc_warn() {
  printf '[CACHE] WARNING: %s\n' "$*" >&2
}

_lld_available() {
  command -v ld.lld >/dev/null 2>&1 || command -v lld >/dev/null 2>&1
}

_ccache_available() {
  command -v ccache >/dev/null 2>&1
}

_sccache_available() {
  command -v sccache >/dev/null 2>&1
}

# Accepts every off spelling; only "false" used to work, so USE_CCACHE=0 was ignored.
_flag_disabled() {
  case "${1:-}" in
    0|false|FALSE|False|no|NO|off|OFF) return 0 ;;
    *) return 1 ;;
  esac
}

# Run in the compiling shell, never in $( ): docs/build-cache-tiers.md#the-server-address-must-be-exported-where-the-compiles-run
sccache_export_server_address() {
  if [ -n "${SCCACHE_SERVER_UDS:-}" ] || [ -n "${SCCACHE_SERVER_PORT:-}" ]; then
    return 0
  fi
  local _scv _scv_maj _scv_rest _scv_min _scp_off
  _scv="$(sccache --version 2>/dev/null | awk '{print $2}')"
  _scv_maj="${_scv%%.*}"; _scv_rest="${_scv#*.}"; _scv_min="${_scv_rest%%.*}"
  if [ "${_scv_maj:-0}" -ge 1 ] 2>/dev/null || [ "${_scv_min:-0}" -ge 14 ] 2>/dev/null; then
    SCCACHE_SERVER_UDS="/tmp/sccache-$(id -u).sock"
    export SCCACHE_SERVER_UDS
  else
    _scp_off="$(printf '%s' "${HOSTNAME:-$$}" | cksum | awk '{print $1 % 20000}')"
    export SCCACHE_SERVER_PORT="$(( 20000 + _scp_off ))"
  fi
}

# Defers to common.sh's compiler_cache_launcher; the inline copy serves the standalone android preamble, and a test keeps them equal.
_resolve_compiler_cache_launcher() {
  if command -v compiler_cache_launcher >/dev/null 2>&1; then
    printf '%s' "$(compiler_cache_launcher 2>/dev/null || true)"
    return 0
  fi
  if command -v sccache >/dev/null 2>&1; then
    sccache_export_server_address
    sccache --start-server >/dev/null 2>&1 || true
    if sccache --show-stats >/dev/null 2>&1; then
      # The guarded launcher survives sccache's own fatal errors, which abort a bare sccache build.
      for _scl in "${_CC_SH_DIR:-}/sccache-launcher.sh" /opt/scripts/core/sccache-launcher.sh; do
        if [ -x "${_scl}" ]; then printf '%s' "${_scl}"; return 0; fi
      done
      printf '%s' sccache
      return 0
    fi
  fi
  printf '%s' ccache
  return 0
}

setup_ccache() {
  if _flag_disabled "${USE_CCACHE}"; then
    _cc_info "ccache disabled via USE_CCACHE=${USE_CCACHE}"
    return 0
  fi

  if ! _ccache_available; then
    _cc_warn "ccache not found in PATH, skipping"
    return 0
  fi

  export CCACHE_DIR
  export CCACHE_MAXSIZE
  export CCACHE_COMPRESS="1"
  export CCACHE_COMPRESSLEVEL="6"
  export CCACHE_SLOPPINESS="pch_defines,time_macros,include_file_mtime,include_file_ctime"

  mkdir -p "${CCACHE_DIR}" 2>/dev/null || true

  # sccache only when its server answers: a dead server fails compiles instead of missing.
  export SCCACHE_IDLE_TIMEOUT="${SCCACHE_IDLE_TIMEOUT:-0}"
  # Off for the same reason as in common.sh's ensure_sccache_env.
  export SCCACHE_DIRECT="${SCCACHE_DIRECT:-false}"
  # Quiet by default; SCCACHE_LOG=sccache=debug brings back the client/server trace.
  export SCCACHE_LOG="${SCCACHE_LOG:-}"
  export SCCACHE_ERROR_LOG="${SCCACHE_ERROR_LOG:-/tmp/sccache.log}"
  _cc_launcher="ccache"
  if ! _flag_disabled "${USE_SCCACHE}"; then
    if _sccache_available; then
      sccache_export_server_address
    fi
    _cc_launcher="$(_resolve_compiler_cache_launcher)"
    case "${_cc_launcher}" in
      *sccache*) : ;;
      *) _cc_launcher="ccache"
         _cc_warn "sccache unusable (absent or server not answering) -- using ccache for C/C++"
         ;;
    esac
  fi
  export CMAKE_C_COMPILER_LAUNCHER="${_cc_launcher}"
  export CMAKE_CXX_COMPILER_LAUNCHER="${_cc_launcher}"

  # Not CC="ccache gcc": CMake would take ccache for the compiler and double-wrap.

  _cc_info "compiler cache enabled: launcher=${_cc_launcher}, CCACHE_DIR=${CCACHE_DIR}, MAXSIZE=${CCACHE_MAXSIZE}"
  _cc_info "CMAKE_C_COMPILER_LAUNCHER=${CMAKE_C_COMPILER_LAUNCHER}"

  # Without -M ccache keeps its compiled-in default, not CCACHE_MAXSIZE.
  ccache -M "${CCACHE_MAXSIZE}" 2>/dev/null || true

  # Substring match: the launcher may be the guarded launcher's path, not the literal "sccache".
  case "${_cc_launcher}" in
    *sccache*) sccache --show-stats 2>/dev/null | grep -E '^(Compile requests|Cache hits|Cache misses|Non-cacheable|Unsupported|Errors)' || true ;;
    *)         ccache --show-stats 2>/dev/null | head -5 || true ;;
  esac
}

setup_sccache() {
  if _flag_disabled "${USE_SCCACHE}"; then
    _cc_info "sccache disabled via USE_SCCACHE=${USE_SCCACHE}"
    return 0
  fi

  if ! _sccache_available; then
    _cc_warn "sccache not found in PATH, skipping"
    return 0
  fi

  export SCCACHE_DIR
  export SCCACHE_CACHE_SIZE

  mkdir -p "${SCCACHE_DIR}" 2>/dev/null || true
  sccache_export_server_address

  # This RUSTC_WRAPPER wins over build-gstreamer-monorepo.sh's; Rust has no ccache fallback, so non-sccache verdicts keep sccache.
  _sc_launcher="sccache"
  _sc_resolved="$(_resolve_compiler_cache_launcher)"
  case "${_sc_resolved}" in
    *sccache*) _sc_launcher="${_sc_resolved}" ;;
    *) : ;;
  esac
  export RUSTC_WRAPPER="${_sc_launcher}"

  if [ -z "${CMAKE_C_COMPILER_LAUNCHER:-}" ]; then
    export CMAKE_C_COMPILER_LAUNCHER="${_sc_launcher}"
    export CMAKE_CXX_COMPILER_LAUNCHER="${_sc_launcher}"
  fi

  _cc_info "sccache enabled: SCCACHE_DIR=${SCCACHE_DIR}, CACHE_SIZE=${SCCACHE_CACHE_SIZE} [server=${SCCACHE_SERVER_UDS:-tcp:${SCCACHE_SERVER_PORT:-4226}}]"
  _cc_info "RUSTC_WRAPPER=${RUSTC_WRAPPER}"

  sccache --start-server 2>/dev/null || true
}

setup_lld_linker() {
  if _flag_disabled "${USE_LLD}"; then
    # Earlier callers may already have added -fuse-ld=lld, which Meson/CMake would inherit.
    local _sl_var _sl_cleaned
    for _sl_var in LDFLAGS CMAKE_EXE_LINKER_FLAGS CMAKE_SHARED_LINKER_FLAGS CMAKE_MODULE_LINKER_FLAGS RUSTFLAGS; do
      if [ -n "${!_sl_var:-}" ]; then
        _sl_cleaned="${!_sl_var}"
        # The compound token goes whole first, or a dangling "-C link-arg=" reaches rustc as "".
        _sl_cleaned="${_sl_cleaned//-C link-arg=-fuse-ld=lld/}"
        _sl_cleaned="${_sl_cleaned//-fuse-ld=lld/}"
        # Defensive: drop any leftover empty "-C link-arg=" tokens.
        _sl_cleaned="$(printf '%s' "${_sl_cleaned}" | sed -E 's/(^|[[:space:]])-C[[:space:]]+link-arg=($|[[:space:]])/ /g')"
        _sl_cleaned="$(printf '%s' "${_sl_cleaned}" | sed 's/[[:space:]]\{2,\}/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//')"
        export "${_sl_var}=${_sl_cleaned}"
      fi
    done
    _cc_info "lld linker disabled via USE_LLD=false"
    return 0
  fi

  if ! _lld_available; then
    _cc_warn "lld not found in PATH, using default linker"
    return 0
  fi

  local lld_flag="-fuse-ld=lld"

  if [ -n "${LDFLAGS:-}" ]; then
    export LDFLAGS="${LDFLAGS} ${lld_flag}"
  else
    export LDFLAGS="${lld_flag}"
  fi

  export CMAKE_EXE_LINKER_FLAGS="${CMAKE_EXE_LINKER_FLAGS:-} ${lld_flag}"
  export CMAKE_SHARED_LINKER_FLAGS="${CMAKE_SHARED_LINKER_FLAGS:-} ${lld_flag}"
  export CMAKE_MODULE_LINKER_FLAGS="${CMAKE_MODULE_LINKER_FLAGS:-} ${lld_flag}"

  local rust_lld_flag="-C link-arg=${lld_flag}"
  if [ -n "${RUSTFLAGS:-}" ]; then
    export RUSTFLAGS="${RUSTFLAGS} ${rust_lld_flag}"
  else
    export RUSTFLAGS="${rust_lld_flag}"
  fi

  _cc_info "lld linker enabled: LDFLAGS contains ${lld_flag}"
}

# Call after each media build step; stderr survives the 2 MiB step-log clip, and zero hits warns of a dead cache.
dump_compiler_cache_stats() {
  if command -v sccache >/dev/null 2>&1; then
    local _req _hits
    # Anchored: "Compile requests executed" and "Cache hits (C/C++)" share the prefixes.
    _req="$(sccache --show-stats 2>/dev/null | awk '/^Compile requests[[:space:]]+[0-9]+[[:space:]]*$/ { print $NF; exit }')"
    _hits="$(sccache --show-stats 2>/dev/null | awk '/^Cache hits[[:space:]]+[0-9]+[[:space:]]*$/ { print $NF; exit }')"
    case "${_req}" in ''|*[!0-9]*) _req=0 ;; esac
    case "${_hits}" in ''|*[!0-9]*) _hits=0 ;; esac
    sccache --show-stats 2>/dev/null | grep -E '^(Compile requests|Cache hits|Cache misses|Non-cacheable|Unsupported|Errors)' >&2 || true
    if [ "${_req}" -gt 0 ] && [ "${_hits}" -eq 0 ]; then
      _cc_warn "sccache: ${_req} compile requests, 0 cache hits — cache may be dead"
    fi
  elif command -v ccache >/dev/null 2>&1; then
    ccache --show-stats 2>/dev/null | head -5 >&2 || true
  fi
}
