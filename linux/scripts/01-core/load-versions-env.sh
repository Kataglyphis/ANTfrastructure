#!/usr/bin/env bash
# versions.env is literal data (e.g. 80;86;89;90), never `source`d; a non-empty env value wins over the file.
[ -n "${_LOAD_VERSIONS_ENV_SH_LOADED:-}" ] && return 0
_LOAD_VERSIONS_ENV_SH_LOADED=1

load_versions_env() {
  local _ve_file="${1:?versions env file required}" _ve_line _ve_name
  # A missing file is tolerated but said out loud, or stale ARG defaults pass for loaded pins.
  if [ ! -f "${_ve_file}" ]; then
    echo "load_versions_env: ${_ve_file} not found; relying on environment/ARG values only." >&2
    return 0
  fi
  while IFS= read -r _ve_line || [ -n "${_ve_line}" ]; do
    case "${_ve_line}" in
      [A-Z]*=*) ;;
      *) continue ;;
    esac
    _ve_name="${_ve_line%%=*}"
    if [ -z "${!_ve_name:-}" ]; then
      _ve_val="${_ve_line#*=}"
      # Strip one pair of quotes, which would otherwise reach CMake as part of the value.
      case "${_ve_val}" in
        \"*\") _ve_val="${_ve_val#\"}"; _ve_val="${_ve_val%\"}" ;;
        \'*\') _ve_val="${_ve_val#\'}"; _ve_val="${_ve_val%\'}" ;;
      esac
      export "${_ve_name}=${_ve_val}"
    fi
  done < "${_ve_file}"
}
