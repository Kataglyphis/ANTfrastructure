#!/usr/bin/env bash
# cmake-cache-linker.sh - shared CMake LLD/ccache fallback flag helpers.
#
# Provides:
#   append_cmake_cache_linker_args <array_ref>
#
# Usage:
#   source /path/to/cmake-cache-linker.sh
#   local -a cmake_opts=()
#   append_cmake_cache_linker_args cmake_opts

[ -n "${_CMAKE_CACHE_LINKER_LOADED:-}" ] && return 0
_CMAKE_CACHE_LINKER_LOADED=1

# Boolean-off check for the cache/linker toggles: accept the fleet's BOTH
# truthiness spellings (0/false/no/off, any case) — "USE_CCACHE=0" used to be
# silently ignored because only the literal string "false" disabled anything.
_flag_disabled() {
  case "${1:-}" in
    0|false|FALSE|False|no|NO|off|OFF) return 0 ;;
    *) return 1 ;;
  esac
}


append_cmake_cache_linker_args() {
  local -n _accla_args=$1

  if command -v ld.lld >/dev/null 2>&1 && ! _flag_disabled "${USE_LLD:-true}"; then
    if [ -z "${CMAKE_EXE_LINKER_FLAGS:-}" ]; then
      _accla_args+=("-DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld")
      _accla_args+=("-DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld")
      _accla_args+=("-DCMAKE_MODULE_LINKER_FLAGS=-fuse-ld=lld")
    fi
  fi

  if command -v ccache >/dev/null 2>&1 && ! _flag_disabled "${USE_CCACHE:-true}"; then
    if [ -z "${CMAKE_C_COMPILER_LAUNCHER:-}" ]; then
      _accla_args+=("-DCMAKE_C_COMPILER_LAUNCHER=ccache")
      _accla_args+=("-DCMAKE_CXX_COMPILER_LAUNCHER=ccache")
      _accla_args+=("-DCMAKE_ASM_COMPILER_LAUNCHER=")
    else
      _accla_args+=("-DCMAKE_ASM_COMPILER_LAUNCHER=")
    fi
  fi
}
