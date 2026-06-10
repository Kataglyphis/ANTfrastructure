#!/usr/bin/env bash
# compiler-cache.sh - Configure ccache/sccache for faster rebuilds
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

if [ -z "${_COMPILER_CACHE_LOADED:-}" ]; then
_COMPILER_CACHE_LOADED=1

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

# Setup ccache for C/C++ compilation
# Sets CMAKE_*_COMPILER_LAUNCHER environment variables for CMake builds
setup_ccache() {
  if [ "${USE_CCACHE}" = "false" ]; then
    _cc_info "ccache disabled via USE_CCACHE=false"
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

  # For CMake-based builds, use the compiler launcher (preferred)
  # This avoids double-wrapping issues when CC/CXX already contain ccache
  export CMAKE_C_COMPILER_LAUNCHER="ccache"
  export CMAKE_CXX_COMPILER_LAUNCHER="ccache"

  # NOTE: We intentionally do NOT set CC="ccache gcc" here.
  # Setting CC/CXX to "ccache <compiler>" causes CMake to detect "ccache"
  # (e.g., /bin/ccache) as the compiler itself, leading to double invocation:
  #   ccache /bin/ccache g++ ...
  # Instead, we rely on CMAKE_*_COMPILER_LAUNCHER for CMake builds.
  # For non-CMake builds (autoconf, make), users should use ccache symlinks
  # or set CC/CXX manually.

  _cc_info "ccache enabled: CCACHE_DIR=${CCACHE_DIR}, MAXSIZE=${CCACHE_MAXSIZE}"
  _cc_info "CMAKE_C_COMPILER_LAUNCHER=${CMAKE_C_COMPILER_LAUNCHER}"

  # Print cache stats if available
  ccache --show-stats 2>/dev/null | head -5 || true
}

# Setup sccache for Rust and C/C++ compilation
# Sets RUSTC_WRAPPER and CMAKE_*_COMPILER_LAUNCHER environment variables
setup_sccache() {
  if [ "${USE_SCCACHE}" = "false" ]; then
    _cc_info "sccache disabled via USE_SCCACHE=false"
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
  if [ "${USE_LLD}" = "false" ]; then
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

# Append CMake cache args for ccache/sccache and lld to a named array.
# Use this in scripts that build CMake args manually rather than exporting
# CMAKE_C_COMPILER_LAUNCHER / CMAKE_LINKER_TYPE environment variables.
#
# Usage: local -a cmake_args=(); append_cmake_cache_args cmake_args
append_cmake_cache_args() {
  local -n _acmca_out=${1}
  if _ccache_available && [ "${USE_CCACHE:-true}" != "false" ]; then
    _acmca_out+=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
  elif _sccache_available && [ "${USE_SCCACHE:-true}" != "false" ]; then
    _acmca_out+=(-DCMAKE_C_COMPILER_LAUNCHER=sccache -DCMAKE_CXX_COMPILER_LAUNCHER=sccache)
  fi
  if _lld_available && [ "${USE_LLD:-true}" != "false" ]; then
    _acmca_out+=(-DCMAKE_LINKER_TYPE=lld)
  fi
}

fi
