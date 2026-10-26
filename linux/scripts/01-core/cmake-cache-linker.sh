#!/usr/bin/env bash
# append_cmake_cache_linker_args <array_ref>: LLD and compiler-cache launcher flags for CMake.

[ -n "${_CMAKE_CACHE_LINKER_LOADED:-}" ] && return 0
# shellcheck source=linux/scripts/01-core/compiler-cache-utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/compiler-cache-utils.sh" || return 1
_CMAKE_CACHE_LINKER_LOADED=1

# <array_ref> <launcher> [prefix]: pthreadpool and XNNPACK FORCE the launchers to whatever CCACHE_BINARY finds, so it is pinned too. See docs/build-cache-tiers.md#a-subproject-that-forces-its-own-launcher
append_cmake_compiler_cache_pin() {
  local -n _accp_args=$1
  local launcher="$2" prefix="${3--D}" name
  [ -n "${launcher}" ] || return 0
  for name in CMAKE_C_COMPILER_LAUNCHER CMAKE_CXX_COMPILER_LAUNCHER CCACHE_BINARY; do
    _accp_args+=("${prefix}${name}=${launcher}")
  done
}

# <build-dir> <launcher>: fails when the configured build's launchers are not the one it was given.
cmake_assert_compiler_cache_pin() {
  local dir="$1" want="$2" cache="$1/CMakeCache.txt" name got rc=0
  [ -n "${want}" ] || return 0
  if [ ! -f "${cache}" ]; then
    printf 'ERROR: [CACHE] %s has no CMakeCache.txt; the compiler-cache pin is unverified\n' "${dir}" >&2
    return 1
  fi
  for name in CMAKE_C_COMPILER_LAUNCHER CMAKE_CXX_COMPILER_LAUNCHER; do
    got="$(sed -n "s/^${name}:[A-Z]*=//p" "${cache}" | head -n 1)"
    if [ "${got}" != "${want}" ]; then
      printf 'ERROR: [CACHE] %s: %s is %s, not %s; a subproject replaced the compiler cache\n' "${dir}" "${name}" "${got:-unset}" "${want}" >&2
      rc=1
    fi
  done
  [ "${rc}" -ne 0 ] || printf '[CACHE] %s compiles through %s\n' "${dir}" "${want}" >&2
  return "${rc}"
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
    else
      _accla_launcher="${CMAKE_CXX_COMPILER_LAUNCHER:-${CMAKE_C_COMPILER_LAUNCHER}}"
    fi
    # shellcheck disable=SC2034  # read back by the caller's cmake_assert_compiler_cache_pin after its configure
    CMAKE_COMPILER_CACHE_PIN="${_accla_launcher}"
    append_cmake_compiler_cache_pin _accla_args "${_accla_launcher}"
    _accla_args+=("-DCMAKE_ASM_COMPILER_LAUNCHER=")
  fi
}
