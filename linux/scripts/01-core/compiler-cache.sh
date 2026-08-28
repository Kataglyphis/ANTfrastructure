#!/usr/bin/env bash
# compiler-cache.sh - ccache/sccache/lld wiring for the 03-media chain ONLY: the
# 02-toolchain builds cache themselves (build-gcc.sh --ccache, build-clang.sh).
# See docs/build-cache-tiers.md.

[ -n "${_COMPILER_CACHE_LOADED:-}" ] && return 0
_COMPILER_CACHE_LOADED=1

_CC_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${USE_CCACHE:=true}"
: "${USE_SCCACHE:=true}"
: "${USE_LLD:=true}"
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

# Accept every truthiness spelling: "USE_CCACHE=0" used to be silently ignored
# because only the literal string "false" disabled anything.
_flag_disabled() {
  case "${1:-}" in
    0|false|FALSE|False|no|NO|off|OFF) return 0 ;;
    *) return 1 ;;
  esac
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

  # Prefer sccache only when its server actually answers: a dead server is a HARD
  # compile failure, not a miss. See docs/build-cache-tiers.md.
  _cc_launcher="ccache"
  if ! _flag_disabled "${USE_SCCACHE}" && command -v sccache >/dev/null 2>&1; then
    export SCCACHE_IDLE_TIMEOUT="${SCCACHE_IDLE_TIMEOUT:-0}"
    # See common.sh:ensure_sccache_env -- preprocessor cache mode re-reads the
    # input file AFTER the compile and dies on CMake's deleted TryCompile dirs.
    export SCCACHE_DIRECT="${SCCACHE_DIRECT:-false}"
    # Quiet by default; SCCACHE_LOG=sccache=debug brings back the client/server trace.
    export SCCACHE_LOG="${SCCACHE_LOG:-}"
    # One server per container: the default TCP port is NOT container-local, so
    # concurrent BuildKit steps reach each other's server (UDS needs sccache >= 0.14,
    # hashed port is the 0.13 fallback). See docs/build-cache-tiers.md.
    if [ -z "${SCCACHE_SERVER_UDS:-}" ] && [ -z "${SCCACHE_SERVER_PORT:-}" ]; then
      _scv="$(sccache --version 2>/dev/null | awk '{print $2}')"
      _scv_maj="${_scv%%.*}"; _scv_rest="${_scv#*.}"; _scv_min="${_scv_rest%%.*}"
      if [ "${_scv_maj:-0}" -ge 1 ] 2>/dev/null || [ "${_scv_min:-0}" -ge 14 ] 2>/dev/null; then
        export SCCACHE_SERVER_UDS="/tmp/sccache-$(id -u).sock"
      else
        _scp_off="$(printf '%s' "${HOSTNAME:-$$}" | cksum | awk '{print $1 % 20000}')"
        export SCCACHE_SERVER_PORT="$(( 20000 + _scp_off ))"
      fi
    fi
    export SCCACHE_ERROR_LOG="${SCCACHE_ERROR_LOG:-/tmp/sccache.log}"
    sccache --start-server >/dev/null 2>&1 || true
    if sccache --show-stats >/dev/null 2>&1; then
      # Guarded launcher, never bare sccache: sccache ABORTS the build on its own
      # fatal errors (ENOENT on CMake's deleted TryCompile cwd) where ccache execs on.
      _cc_launcher="sccache"
      for _scl in "${_CC_SH_DIR:-}/sccache-launcher.sh" /opt/scripts/core/sccache-launcher.sh; do
        if [ -x "${_scl}" ]; then _cc_launcher="${_scl}"; break; fi
      done
    else
      _cc_warn "sccache present but its server does not answer -- using ccache for C/C++"
    fi
  fi
  export CMAKE_C_COMPILER_LAUNCHER="${_cc_launcher}"
  export CMAKE_CXX_COMPILER_LAUNCHER="${_cc_launcher}"

  # Deliberately NOT CC="ccache gcc": CMake would detect ccache itself as the
  # compiler and double-wrap (ccache /bin/ccache g++ ...).

  _cc_info "compiler cache enabled: launcher=${_cc_launcher}, CCACHE_DIR=${CCACHE_DIR}, MAXSIZE=${CCACHE_MAXSIZE}"
  _cc_info "CMAKE_C_COMPILER_LAUNCHER=${CMAKE_C_COMPILER_LAUNCHER}"

  # Without -M, ccache uses its compiled-in ~5G default, not CCACHE_MAXSIZE. sccache
  # has no equivalent: its cap comes from SCCACHE_CACHE_SIZE in Dockerfile.base.
  ccache -M "${CCACHE_MAXSIZE}" 2>/dev/null || true

  # SUBSTRING, not identity: _cc_launcher is a PATH to the guarded launcher, not the
  # literal "sccache". A zero-hit report is the cheapest early warning of a dead cache.
  case "${_cc_launcher}" in
    *sccache*) sccache --show-stats 2>/dev/null | head -12 || true ;;
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

  # Guarded launcher, never the bare string (AGENTS.md): setup-gstreamer.sh calls this
  # BEFORE build-gstreamer-monorepo.sh tests `[ -z "${RUSTC_WRAPPER+x}" ]`, so whatever
  # is set here wins.
  _sc_launcher="sccache"
  for _scl in "${_CC_SH_DIR:-}/sccache-launcher.sh" /opt/scripts/core/sccache-launcher.sh; do
    if [ -x "${_scl}" ]; then _sc_launcher="${_scl}"; break; fi
  done
  export RUSTC_WRAPPER="${_sc_launcher}"

  if [ -z "${CMAKE_C_COMPILER_LAUNCHER:-}" ]; then
    export CMAKE_C_COMPILER_LAUNCHER="${_sc_launcher}"
    export CMAKE_CXX_COMPILER_LAUNCHER="${_sc_launcher}"
  fi

  _cc_info "sccache enabled: SCCACHE_DIR=${SCCACHE_DIR}, CACHE_SIZE=${SCCACHE_CACHE_SIZE}"
  _cc_info "RUSTC_WRAPPER=${RUSTC_WRAPPER}"

  sccache --start-server 2>/dev/null || true
}

setup_lld_linker() {
  if _flag_disabled "${USE_LLD}"; then
    # Earlier callers (e.g. media_common_init) may have added -fuse-ld=lld before
    # USE_LLD was set to false; Meson/CMake would inherit the stale flags.
    local _sl_var _sl_cleaned
    for _sl_var in LDFLAGS CMAKE_EXE_LINKER_FLAGS CMAKE_SHARED_LINKER_FLAGS CMAKE_MODULE_LINKER_FLAGS RUSTFLAGS; do
      if [ -n "${!_sl_var:-}" ]; then
        _sl_cleaned="${!_sl_var}"
        # Strip RUSTFLAGS' compound token WHOLE first: removing only "-fuse-ld=lld"
        # leaves a dangling "-C link-arg=" that rustc forwards as an empty "" argument.
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
