#!/usr/bin/env bash
[ -n "${_PATH_HELPERS_SH_LOADED:-}" ] && return 0
_PATH_HELPERS_SH_LOADED=1

# SUDO expands only when a link is needed, with each caller retaining its required or optional policy.
path_symlink_missing() {
  [ ! -e "$2" ] || return 0
  if [ "$4" = required ]; then
    $SUDO ln "$3" "$1" "$2"
  else
    ${SUDO:-} ln "$3" "$1" "$2"
  fi
}

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
    export "${__varname}=${!__varname}"
  else
    if _path_contains "$__cur" "$__value"; then
      return 0
    fi
    printf -v "${__varname}" '%s:%s' "${__value}" "${__cur}"
    export "${__varname}=${!__varname}"
  fi
}

# Roots are lexical boundaries; callers retain their original trailing-slash policy.
path_under_roots() {
  local policy="$1" path="$2" root
  shift 2
  for root in "$@"; do
    if [ "$policy" = trim-one ]; then root="${root%/}"; fi
    [ -n "$root" ] || continue
    case "$path" in "$root" | "$root"/*) return 0 ;; esac
  done
  return 1
}
