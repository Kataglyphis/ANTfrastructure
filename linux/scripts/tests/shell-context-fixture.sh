#!/usr/bin/env bash
# Direct probes inherit errexit; conditional probes capture failure without suppressing the caller's later assertions.
shell_fixture_run_context() {
  local _sfrc_context="$1"
  local -n _sfrc_status="$2"
  shift 2
  _sfrc_status=0
  case "${_sfrc_context}" in
    direct) "$@"; _sfrc_status=$? ;;
    conditional) if "$@"; then _sfrc_status=0; else _sfrc_status=$?; fi ;;
    *) printf 'Unknown shell fixture context: %s\n' "${_sfrc_context}" >&2; return 2 ;;
  esac
  return 0
}
