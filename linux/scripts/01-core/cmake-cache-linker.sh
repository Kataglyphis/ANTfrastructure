#!/usr/bin/env bash
# append_cmake_cache_linker_args <array_ref>: LLD and compiler-cache launcher flags for CMake.

[ -n "${_CMAKE_CACHE_LINKER_LOADED:-}" ] && return 0
_CMAKE_CACHE_LINKER_LOADED=1

# Accepts every off spelling (0/false/no/off); only "false" used to work, so USE_CCACHE=0 was ignored.
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
      # sccache when usable, else ccache; hardcoding ccache would override the switch for every consumer.
      compiler_cache_launcher_env 2>/dev/null || true
      _accla_launcher="$(compiler_cache_launcher 2>/dev/null || echo ccache)"
      _accla_args+=("-DCMAKE_C_COMPILER_LAUNCHER=${_accla_launcher}")
      _accla_args+=("-DCMAKE_CXX_COMPILER_LAUNCHER=${_accla_launcher}")
      _accla_args+=("-DCMAKE_ASM_COMPILER_LAUNCHER=")
    else
      _accla_args+=("-DCMAKE_ASM_COMPILER_LAUNCHER=")
    fi
  fi
}
