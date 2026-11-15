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

# Boolean caches must reject duplicate values while launcher checks retain first-value policy; neither proves compilation.
cmake_assert_configured_entries() {
  local _cce_cache="$1/CMakeCache.txt" _cce_mode="$2" _cce_pattern _cce_entry _cce_name _cce_want _cce_got _cce_rc=0
  case "${_cce_mode}" in first) _cce_pattern='[A-Z]*' ;; bool) _cce_pattern=BOOL ;; *) return 2 ;; esac
  shift 2
  [ "$#" -gt 0 ] || return 2
  if [ ! -f "${_cce_cache}" ]; then
    printf 'ERROR: [CMAKE] %s has no CMakeCache.txt; configured entries are unverified\n' "${_cce_cache%/*}" >&2
    return 1
  fi
  for _cce_entry in "$@"; do
    case "${_cce_entry}" in *=*) ;; *) return 2 ;; esac
    _cce_name="${_cce_entry%%=*}"; _cce_want="${_cce_entry#*=}"
    _cce_got="$(sed -n "s/^${_cce_name}:${_cce_pattern}=//p" "${_cce_cache}")" || return $?
    if [ "${_cce_mode}" = first ]; then _cce_got="${_cce_got%%$'\n'*}"; else _cce_got="${_cce_got//$'\r'/}"; fi
    if [ "${_cce_got}" != "${_cce_want}" ]; then
      printf 'ERROR: [CMAKE] %s: %s=%s, expected %s\n' "${_cce_cache}" "${_cce_name}" "${_cce_got:-<unset>}" "${_cce_want}" >&2
      _cce_rc=1
    fi
  done
  return "${_cce_rc}"
}

# <build-dir> <launcher>: fails when the configured build's launchers are not the one it was given.
cmake_assert_compiler_cache_pin() {
  local dir="$1" want="$2"
  [ -n "${want}" ] || return 0
  if ! cmake_assert_configured_entries "${dir}" first \
      "CMAKE_C_COMPILER_LAUNCHER=${want}" "CMAKE_CXX_COMPILER_LAUNCHER=${want}"; then
    printf 'ERROR: [CACHE] %s: a subproject replaced the compiler cache or the configure cache is unverified\n' "${dir}" >&2
    return 1
  fi
  printf '[CACHE] %s compiles through %s\n' "${dir}" "${want}" >&2
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
