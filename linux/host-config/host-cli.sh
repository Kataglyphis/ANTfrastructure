# shellcheck shell=bash
# The host-config scripts' one argument loop, so --help and an unknown argument behave the same in each.
# shellcheck source=../scripts/lib/cli-value-options.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/cli-value-options.sh"

# host_cli_parse <script> <value-options-map> <switch-fn|-> "$@": switch-fn returns 1 for a switch it took, 0 otherwise.
host_cli_parse() {
  _HOST_CLI_SCRIPT="$1" _HOST_CLI_SWITCH="$3"
  local _hcp_map="$2"
  local -a _hcp_rest=()
  shift 3
  parse_cli_value_options "${_hcp_map}" _hcp_rest _host_cli_other_arg "$@"
}

_host_cli_other_arg() {
  local took=0
  if [ "${_HOST_CLI_SWITCH}" != - ]; then
    "${_HOST_CLI_SWITCH}" "$1" || took=$?
  fi
  if [ "${took}" != 0 ]; then return "${took}"; fi
  case "$1" in
    -h|--help) sed -n '2p' "${_HOST_CLI_SCRIPT}"; exit 0 ;;
    *) printf '%s: unknown argument: %s\n' "$(basename "${_HOST_CLI_SCRIPT}" .sh)" "$1" >&2; exit 2 ;;
  esac
}
