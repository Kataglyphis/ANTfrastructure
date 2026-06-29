#!/usr/bin/env bash
[ -n "${_PATH_HELPERS_SH_LOADED:-}" ] && return 0
_PATH_HELPERS_SH_LOADED=1

_path_contains() {
  local var="$1" cand="$2"
  [ -n "$var" ] || return 1
  case ":$var:" in
    *":${cand}:"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Append a colon-separated value to a path-style env var only if not present.
#   Usage: append_unique_colon_path VARNAME value
#   Example: append_unique_colon_path PKG_CONFIG_PATH /usr/local/lib/pkgconfig
# The variable name is taken as a nameref-free global (set via printf -v + export)
# so it is safe to call from any context (functions, subshells).
append_unique_colon_path() {
  local varname="$1" value="$2"
  local cur="${!varname:-}"
  if [ -z "${cur}" ]; then
    printf -v "${varname}" '%s' "${value}"
  elif ! _path_contains "${cur}" "${value}"; then
    printf -v "${varname}" '%s:%s' "${cur}" "${value}"
  fi
  export "${varname}"
}

_path_prepend_unique() {
  local __varname="$1" __value="$2"
  local __cur
  __cur="${!__varname:-}"
  if [ -z "$__cur" ]; then
    printf -v "${__varname}" '%s' "${__value}"
    export "${__varname}"
  else
    if _path_contains "$__cur" "$__value"; then
      return 0
    fi
    printf -v "${__varname}" '%s:%s' "${__value}" "${__cur}"
    export "${__varname}"
  fi
}
