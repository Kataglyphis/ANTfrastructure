#!/usr/bin/env bash
# compiler-cache.sh - Configure ccache/sccache for faster rebuilds
#
# CONSUMERS: the 03-media build chain ONLY (media_common_init and the
# onnxruntime build lib). The 02-toolchain GCC/LLVM builds do NOT source this
# module — their ccache wiring lives in build-gcc.sh (--ccache flag) and
# build-clang.sh (CMAKE_*_COMPILER_LAUNCHER). Do not read this file as the
# toolchain caching story; that misread hid a dead ccache mount for months.
#
# Provides:
#   setup_ccache       - Configure ccache for C/C++ compilation
#   setup_sccache      - Configure sccache for Rust and C/C++ compilation
#   setup_lld_linker   - Configure lld as the default linker
#   get_linker_flags   - Return linker flags for the configured linker
#
# Usage:
#   source /path/to/compiler-cache.sh
#   setup_ccache
#   setup_lld_linker
#
# Environment Variables:
#   USE_CCACHE          - Set to "false" to disable ccache (default: true)
#   USE_SCCACHE         - Set to "false" to disable sccache (default: true)
#   USE_LLD             - Set to "false" to disable lld linker (default: true)
#   CCACHE_DIR          - ccache cache directory (default: /var/cache/ccache)
#   CCACHE_MAXSIZE      - ccache max size (default: 10G)
#   SCCACHE_DIR         - sccache cache directory (default: /var/cache/sccache)
#   SCCACHE_CACHE_SIZE  - sccache max size (default: 10G)

[ -n "${_COMPILER_CACHE_LOADED:-}" ] && return 0
_COMPILER_CACHE_LOADED=1

_CC_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default settings
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

# Check if lld is available
_lld_available() {
  command -v ld.lld >/dev/null 2>&1 || command -v lld >/dev/null 2>&1
}

# Check if ccache is available
_ccache_available() {
  command -v ccache >/dev/null 2>&1
}

# Check if sccache is available
_sccache_available() {
  command -v sccache >/dev/null 2>&1
}

# Boolean-off check for the cache/linker toggles: accept the fleet's BOTH
# truthiness spellings (0/false/no/off, any case) — "USE_CCACHE=0" used to be
# silently ignored because only the literal string "false" disabled anything.
_flag_disabled() {
  case "${1:-}" in
    0|false|FALSE|False|no|NO|off|OFF) return 0 ;;
    *) return 1 ;;
  esac
}

# Setup ccache for C/C++ compilation
# Sets CMAKE_*_COMPILER_LAUNCHER environment variables for CMake builds
setup_ccache() {
  if _flag_disabled "${USE_CCACHE}"; then
    _cc_info "ccache disabled via USE_CCACHE=${USE_CCACHE}"
    return 0
  fi

  if ! _ccache_available; then
    _cc_warn "ccache not found in PATH, skipping"
    return 0
  fi

  # Configure ccache settings
  export CCACHE_DIR
  export CCACHE_MAXSIZE
  export CCACHE_COMPRESS="1"
  export CCACHE_COMPRESSLEVEL="6"
  export CCACHE_SLOPPINESS="pch_defines,time_macros,include_file_mtime,include_file_ctime"

  # Create cache directory if it doesn't exist
  mkdir -p "${CCACHE_DIR}" 2>/dev/null || true

  # For CMake-based builds, use the compiler LAUNCHER (preferred).
  # This avoids double-wrapping issues when CC/CXX already contain a cache.
  #
  # 2026-08-26 (ccache->sccache switch): pick sccache when it is present AND
  # its server answers, else stay on ccache. The server check is not ceremony:
  # sccache is a client/daemon pair and a dead server is a HARD compile
  # failure, not a miss -- this repo has recorded that exact death killing
  # media builds at 99%.
  _cc_launcher="ccache"
  if ! _flag_disabled "${USE_SCCACHE}" && command -v sccache >/dev/null 2>&1; then
    export SCCACHE_IDLE_TIMEOUT="${SCCACHE_IDLE_TIMEOUT:-0}"
    # See common.sh:ensure_sccache_env -- preprocessor cache mode re-reads the
    # input file AFTER the compile and dies on CMake's deleted TryCompile dirs.
    export SCCACHE_DIRECT="${SCCACHE_DIRECT:-false}"
    # DIAGNOSTIC (2026-08-26, temporary): sccache fails to spawn the compiler
    # for every object in some CMake sub-builds (opencv 3rdparty/ippicv,
    # onnxruntime _deps/*), reporting ENOENT although both the compiler and the
    # cwd demonstrably exist. TWELVE isolated hypotheses have been disproven, so
    # stop guessing and let sccache report what it resolved. Default-on because
    # a run that reproduces the failure WITHOUT the log is a wasted run; set
    # SCCACHE_LOG= to silence it. Remove once the cause is known.
    export SCCACHE_LOG="${SCCACHE_LOG:-sccache=debug}"
    export SCCACHE_ERROR_LOG="${SCCACHE_ERROR_LOG:-/tmp/sccache.log}"
    sccache --start-server >/dev/null 2>&1 || true
    if sccache --show-stats >/dev/null 2>&1; then
      # Use the GUARDED launcher when it is reachable. Bare sccache aborts the
      # build on its own fatal errors (CMake deletes TryCompile scratch dirs,
      # sccache then spawns with a cwd that no longer exists -> ENOENT). This
      # module resolved the launcher itself and hardcoded "sccache", which is
      # why the guard did not take effect on the first attempt.
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

  # NOTE: We intentionally do NOT set CC="ccache gcc" here.
  # Setting CC/CXX to "ccache <compiler>" causes CMake to detect "ccache"
  # (e.g., /bin/ccache) as the compiler itself, leading to double invocation:
  #   ccache /bin/ccache g++ ...
  # Instead, we rely on CMAKE_*_COMPILER_LAUNCHER for CMake builds.
  # For non-CMake builds (autoconf, make), users should use ccache symlinks
  # or set CC/CXX manually.

  _cc_info "compiler cache enabled: launcher=${_cc_launcher}, CCACHE_DIR=${CCACHE_DIR}, MAXSIZE=${CCACHE_MAXSIZE}"
  _cc_info "CMAKE_C_COMPILER_LAUNCHER=${CMAKE_C_COMPILER_LAUNCHER}"

  # Apply the max-size limit to the on-disk cache. Without this, ccache
  # uses its compiled-in default (~5G), not the CCACHE_MAXSIZE env var.
  # sccache has NO equivalent command: its cap comes from SCCACHE_CACHE_SIZE
  # plus the config file baked into Dockerfile.base, which is exactly why that
  # ENV must not be forgotten -- there is nothing here that could set it.
  ccache -M "${CCACHE_MAXSIZE}" 2>/dev/null || true

  # Print cache stats. A zero-hit report is the cheapest early warning that
  # caching silently stopped working after this switch.
  if [ "${_cc_launcher}" = "sccache" ]; then
    sccache --show-stats 2>/dev/null | head -12 || true
  else
    ccache --show-stats 2>/dev/null | head -5 || true
  fi
}

# Setup sccache for Rust and C/C++ compilation
# Sets RUSTC_WRAPPER and CMAKE_*_COMPILER_LAUNCHER environment variables
setup_sccache() {
  if _flag_disabled "${USE_SCCACHE}"; then
    _cc_info "sccache disabled via USE_SCCACHE=${USE_SCCACHE}"
    return 0
  fi

  if ! _sccache_available; then
    _cc_warn "sccache not found in PATH, skipping"
    return 0
  fi

  # Configure sccache settings
  export SCCACHE_DIR
  export SCCACHE_CACHE_SIZE

  # Create cache directory if it doesn't exist
  mkdir -p "${SCCACHE_DIR}" 2>/dev/null || true

  # Set up Rust wrapper
  export RUSTC_WRAPPER="sccache"

  # Note: If ccache is already set up, we don't override CMAKE_*_COMPILER_LAUNCHER
  # sccache for Rust, ccache for C/C++ is the recommended setup
  if [ -z "${CMAKE_C_COMPILER_LAUNCHER:-}" ]; then
    export CMAKE_C_COMPILER_LAUNCHER="sccache"
    export CMAKE_CXX_COMPILER_LAUNCHER="sccache"
  fi

  _cc_info "sccache enabled: SCCACHE_DIR=${SCCACHE_DIR}, CACHE_SIZE=${SCCACHE_CACHE_SIZE}"
  _cc_info "RUSTC_WRAPPER=${RUSTC_WRAPPER}"

  # Start sccache server if not running
  sccache --start-server 2>/dev/null || true
}

# Setup lld as the default linker
# Sets LDFLAGS and provides CMAKE flags
setup_lld_linker() {
  if _flag_disabled "${USE_LLD}"; then
    # Strip any -fuse-ld=lld previously added to environment variables.
    # Earlier callers (e.g. media_common_init) may have populated these before
    # USE_LLD was set to false, and Meson/CMake will inherit the stale flags.
    local _sl_var _sl_cleaned
    for _sl_var in LDFLAGS CMAKE_EXE_LINKER_FLAGS CMAKE_SHARED_LINKER_FLAGS CMAKE_MODULE_LINKER_FLAGS RUSTFLAGS; do
      if [ -n "${!_sl_var:-}" ]; then
        _sl_cleaned="${!_sl_var}"
        # RUSTFLAGS carries lld as the compound token "-C link-arg=-fuse-ld=lld".
        # Strip it WHOLE first, otherwise removing just "-fuse-ld=lld" below leaves
        # a dangling "-C link-arg=" (empty value) that rustc forwards to the linker
        # as an empty "" argument -> "aarch64-linux-gnu-ld.bfd: cannot find : No
        # such file or directory". (Latent until cross Rust linking was enabled for
        # gst-plugins-rs; each earlier append leaves one, hence the "" "" pair.)
        _sl_cleaned="${_sl_cleaned//-C link-arg=-fuse-ld=lld/}"
        # Bare form in LDFLAGS / CMAKE_* linker flags.
        _sl_cleaned="${_sl_cleaned//-fuse-ld=lld/}"
        # Defensive: drop any leftover empty "-C link-arg=" tokens.
        _sl_cleaned="$(printf '%s' "${_sl_cleaned}" | sed -E 's/(^|[[:space:]])-C[[:space:]]+link-arg=($|[[:space:]])/ /g')"
        # Collapse repeated whitespace and trim
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

  # Set linker flags for various build systems
  local lld_flag="-fuse-ld=lld"

  # Append to existing LDFLAGS if present
  if [ -n "${LDFLAGS:-}" ]; then
    export LDFLAGS="${LDFLAGS} ${lld_flag}"
  else
    export LDFLAGS="${lld_flag}"
  fi

  # Export for CMake
  export CMAKE_EXE_LINKER_FLAGS="${CMAKE_EXE_LINKER_FLAGS:-} ${lld_flag}"
  export CMAKE_SHARED_LINKER_FLAGS="${CMAKE_SHARED_LINKER_FLAGS:-} ${lld_flag}"
  export CMAKE_MODULE_LINKER_FLAGS="${CMAKE_MODULE_LINKER_FLAGS:-} ${lld_flag}"

  # Export for Rust/Cargo (RUSTFLAGS)
  local rust_lld_flag="-C link-arg=${lld_flag}"
  if [ -n "${RUSTFLAGS:-}" ]; then
    export RUSTFLAGS="${RUSTFLAGS} ${rust_lld_flag}"
  else
    export RUSTFLAGS="${rust_lld_flag}"
  fi

  _cc_info "lld linker enabled: LDFLAGS contains ${lld_flag}"
}
