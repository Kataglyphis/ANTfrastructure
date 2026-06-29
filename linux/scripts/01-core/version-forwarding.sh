#!/usr/bin/env bash
# version-forwarding.sh — auto-discover version vars from versions.env and
# forward them as --build-arg to nerdctl build.
#
# Provides:
#   append_version_build_args()   — append --build-arg VAR=$VAR for all tracked versions
[ -n "${_VERSION_FORWARDING_SH_LOADED:-}" ] && return 0
_VERSION_FORWARDING_SH_LOADED=1

_VF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cache file tracks which version variables exist in versions.env so we only
# parse the file once (or when it changes).
_VBA_CACHE_FILE="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/opencode/.version-build-arg-vars"

# Normally sourced by artifact-common.sh first; this is a standalone safety guard.
# shellcheck disable=SC1090,SC1091
if [ -z "${_BUILD_HELPERS_LOADED:-}" ] && [ -f "${_VF_DIR}/build-helpers.sh" ]; then
  source "${_VF_DIR}/build-helpers.sh"
fi

_auto_discover_version_build_arg_vars() {
  local versions_file="${_VF_DIR}/versions.env"
  [ -f "${versions_file}" ] || return 0

  if [ -f "${_VBA_CACHE_FILE}" ] && [ "${_VBA_CACHE_FILE}" -nt "${versions_file}" ]; then
    return 0
  fi

  mkdir -p "$(dirname "${_VBA_CACHE_FILE}")"
  local _tmp_cache
  _tmp_cache="$(mktemp "${_VBA_CACHE_FILE}.XXXXXX")"
  awk -F= '/^[A-Z][A-Z0-9_]*(_VERSION|_RELEASE|_MAJOR_MINOR|_MAJOR|_REF|_API_LEVEL|_BUILD_TOOLS|_COMPILE_SDK)=/{print $1}' "${versions_file}" > "${_tmp_cache}" || {
    printf 'WARNING: Failed to parse %s\n' "${versions_file}" >&2
    return 1
  }
  if [ ! -s "${_tmp_cache}" ]; then
    printf 'WARNING: No version variables discovered in %s\n' "${versions_file}" >&2
    rm -f "${_tmp_cache}"
    return 1
  fi
  mv "${_tmp_cache}" "${_VBA_CACHE_FILE}"
}

if [ -z "${_VERSION_BUILD_ARG_VARS_CACHED:-}" ]; then
  _auto_discover_version_build_arg_vars
  _VERSION_BUILD_ARG_VARS=()
  while IFS= read -r varname; do
    [ -n "${varname}" ] && _VERSION_BUILD_ARG_VARS+=("${varname}")
  done < "${_VBA_CACHE_FILE}"
  _VERSION_BUILD_ARG_VARS_CACHED=1
fi

append_version_build_args() {
  local _avba_name="$1"
  local var_name
  for var_name in "${_VERSION_BUILD_ARG_VARS[@]}"; do
    if [ -n "${!var_name:-}" ]; then
      append_optional_build_arg "${_avba_name}" "${var_name}" "${!var_name}"
    fi
  done
}
