#!/usr/bin/env bash
# Caller probes share isolated workspaces and companion loading without executing media entrypoints.
source "$(dirname "${BASH_SOURCE[0]}")/test-harness.sh"
source "${_T_SCRIPTS}/tests/gstreamer-fixtures.sh"
export repo="${1:-${_T_SCRIPTS}/../..}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cross_build_is_active() {
  if [ "${mode:-cross}" = native ]; then return 1; else return 0; fi
}

probe_receipt="${2:-}"
media_probe_record() {
  local value
  local -a fields=()
  for value in "$@"; do fields+=("${value//"$work"/@WORK@}"); done
  t_record_fixture_receipt "$probe_receipt" "${fields[@]}"
}

media_probe_answer() {
  local label="$1" value="$2" scenario="$3" trace="$4"
  printf '%s\n' "$label" >> "$trace"
  [ "$scenario" != empty ] || return 7
  printf '%s' "$value"
  [ "$scenario" != partial ] || return 8
  return 0
}

media_probe_hide_commands() {
  _media_probe_hidden=("$@")
  command() {
    local hidden
    if [ "${1:-}" = -v ]; then
      for hidden in "${_media_probe_hidden[@]}"; do
        [ "${2:-}" != "$hidden" ] || return 1
      done
    fi
    builtin command "$@"
  }
}

media_probe_restore_commands() {
  unset -f command
}
