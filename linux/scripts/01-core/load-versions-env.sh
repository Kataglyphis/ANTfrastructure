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
  [ -f "${_ve_file}" ] || return 0
  while IFS= read -r _ve_line || [ -n "${_ve_line}" ]; do
    case "${_ve_line}" in
      [A-Z]*=*) ;;
      *) continue ;;
    esac
    _ve_name="${_ve_line%%=*}"
    if [ -z "${!_ve_name:-}" ]; then
      export "${_ve_name}=${_ve_line#*=}"
    fi
  done < "${_ve_file}"
}
