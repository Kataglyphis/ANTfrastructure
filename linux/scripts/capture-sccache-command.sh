#!/usr/bin/env bash
# Compiler-cache evidence must survive a failing command without changing its raw failure status.
set -euo pipefail
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${scripts}/lib/cli-value-options.sh"
cli_require_positionals 'NEW_OUTPUT -- COMMAND [ARG...]' 3 0 "$@"
[[ "$2" == -- ]] || { printf 'Expected -- before COMMAND\n' >&2; exit 2; }
output_directory="$1"
shift 2
mkdir "${output_directory}"
output_directory="$(cd "${output_directory}" && pwd)"
finish() {
  local result=$? cache_result=0
  trap - EXIT
  sccache --show-stats 2>&1 | tee "${output_directory}/cache-stats.txt" >&2 || cache_result=$?
  sccache --show-stats --stats-format=json > "${output_directory}/cache-stats.json" || cache_result=$?
  printf 'command_status=%s\ncache_stats_status=%s\n' "${result}" "${cache_result}" > "${output_directory}/exit-status.txt"
  if [[ "${result}" == 0 && "${cache_result}" != 0 ]]; then result="${cache_result}"; fi
  exit "${result}"
}
trap finish EXIT
"$@"
