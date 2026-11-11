#!/usr/bin/env bash
# A shared value-option contract prevents launchers from spinning on a missing argument.
[ -n "${_CLI_VALUE_OPTIONS_LOADED:-}" ] && return 0
_CLI_VALUE_OPTIONS_LOADED=1
# shellcheck source=log-bootstrap.sh
source "$(dirname "${BASH_SOURCE[0]}")/log-bootstrap.sh"

assign_cli_value_option() {
  local -n _cvo_options="$1"
  local _cvo_flag="$2" _cvo_value="$3" _cvo_count="$4"
  [ -n "${_cvo_flag}" ] || return 1
  [ -n "${_cvo_options[${_cvo_flag}]:-}" ] || return 1
  [ "${_cvo_count}" -ge 2 ] || err "${_cvo_flag} expects a value"
  printf -v "${_cvo_options[${_cvo_flag}]}" '%s' "${_cvo_value}"
}

# Tool-specific callbacks keep their stopping rules while one loop owns argument movement.
parse_cli_value_options() {
  local _cpo_map="$1" _cpo_handler="$3" _cpo_consumed
  local -n _cpo_remaining="$2"
  shift 3
  while [ "$#" -gt 0 ]; do
    if assign_cli_value_option "${_cpo_map}" "$1" "${2-}" "$#"; then
      shift 2
      continue
    fi
    _cpo_consumed=0
    # Bound callbacks keep the caller's active errexit policy.
    if [[ "${_cpo_handler}" == +* ]]; then
      "${_cpo_handler:1}" _cpo_consumed "$@"
    else
      "${_cpo_handler}" "$@" || _cpo_consumed=$?
    fi
    case "${_cpo_consumed}" in
      0) break ;;
      1|2) shift "${_cpo_consumed}" ;;
      3) shift; break ;;
      *) err "${_cpo_handler} returned an invalid argument count: ${_cpo_consumed}" ;;
    esac
  done
  _cpo_remaining+=("$@")
}

append_cli_nonempty_args() {
  local -n _cna_args="$1"
  local _cna_prefix="$2" _cna_value
  shift 2
  for _cna_value in "$@"; do
    [[ -n "${_cna_value}" ]] || continue
    if [[ -n "${_cna_prefix}" ]]; then _cna_args+=("${_cna_prefix}"); fi
    _cna_args+=("${_cna_value}")
  done
}

cli_require_positionals() {
  local _crp_usage="$1" _crp_min="$2" _crp_max="$3"
  shift 3
  if [[ "${1:-}" == --help ]]; then
    printf 'Usage: %s %s\n' "${0##*/}" "${_crp_usage}"
    exit 0
  fi
  if [[ "$#" -lt "${_crp_min}" || ( "${_crp_max}" -gt 0 && "$#" -gt "${_crp_max}" ) ]]; then
    printf 'Usage: %s %s\n' "${0##*/}" "${_crp_usage}" >&2
    exit 2
  fi
}
