#!/usr/bin/env bash
# load-versions-env.sh — safe loader for versions.env-style KEY=value files.
#
# versions.env is inert data parsed literally by shell, PowerShell, Python,
# and awk consumers alike; values may contain characters the shell would
# interpret (e.g. CUDA_ARCHITECTURES=80;86;89;90), so it must never be
# `source`d directly.
#
# Provides:
#   load_versions_env <file>  — export each KEY=value line, skipping comments
#       and blank lines. Variables already set to a non-empty value in the
#       environment take precedence (Dockerfile ARG/ENV values forwarded by
#       the orchestrator must win over the copy baked into an image).
[ -n "${_LOAD_VERSIONS_ENV_SH_LOADED:-}" ] && return 0
_LOAD_VERSIONS_ENV_SH_LOADED=1

load_versions_env() {
  local _ve_file="${1:?versions env file required}" _ve_line _ve_name
  # A missing file is tolerated (env/ARG values may already provide everything),
  # but say so — a silently-skipped versions.env previously read as "loaded"
  # and left consumers running on stale Dockerfile ARG defaults.
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
      # Strip one pair of surrounding quotes. The file format is unquoted
      # (values are inert data, never shell-evaluated), but a quoted value
      # slipped in once and the quotes propagated as DATA all the way into
      # CMake — CUDA_ARCHITECTURES became ["80;86;89;90"], silently defeating
      # the 90→90a suffix transform. Defense in depth for the whole class.
      case "${_ve_val}" in
        \"*\") _ve_val="${_ve_val#\"}"; _ve_val="${_ve_val%\"}" ;;
        \'*\') _ve_val="${_ve_val#\'}"; _ve_val="${_ve_val%\'}" ;;
      esac
      export "${_ve_name}=${_ve_val}"
    fi
  done < "${_ve_file}"
}
