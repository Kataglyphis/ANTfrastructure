#!/usr/bin/env bash
# version-forwarding.sh — auto-discover version vars from versions.env and
# forward them as --build-arg to nerdctl build.
#
# Provides:
#   append_version_build_args()   — append --build-arg VAR=$VAR for all tracked versions

_VF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cache file tracks which version variables exist in versions.env so we only
# parse the file once (or when it changes).
_VBA_CACHE_FILE="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/opencode/.version-build-arg-vars"

# shellcheck disable=SC1090,SC1091
[ -f "${_VF_DIR}/build-helpers.sh" ] && source "${_VF_DIR}/build-helpers.sh"

_auto_discover_version_build_arg_vars() {
  local versions_file="${_VF_DIR}/versions.env"
  [ -f "${versions_file}" ] || return 0

  if [ -f "${_VBA_CACHE_FILE}" ] && [ "${_VBA_CACHE_FILE}" -nt "${versions_file}" ]; then
    return 0
  fi

  mkdir -p "$(dirname "${_VBA_CACHE_FILE}")"
  local _tmp_cache
  _tmp_cache="$(mktemp "${_VBA_CACHE_FILE}.XXXXXX")"
  grep -E '^[A-Z][A-Z0-9_]*(_VERSION|_RELEASE|_MAJOR_MINOR|_MAJOR|_REF|_API_LEVEL|_BUILD_TOOLS|_COMPILE_SDK)=' "${versions_file}" \
    | cut -d= -f1 > "${_tmp_cache}"
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
