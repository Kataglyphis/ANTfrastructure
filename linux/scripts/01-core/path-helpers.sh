#!/usr/bin/env bash
_PATH_HELPERS_SH_LOADED=true

_path_contains() {
  local var="$1" cand="$2"
  [ -n "$var" ] || return 1
  case ":$var:" in
    *":${cand}:"*) return 0 ;;
    *) return 1 ;;
  esac
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
