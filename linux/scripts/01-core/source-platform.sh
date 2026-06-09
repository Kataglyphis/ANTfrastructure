#!/usr/bin/env bash
# source-platform.sh
# Single-call platform.sh sourcing that works from both repo-layout and
# container-layout script locations.  Sources platform.sh and hard-fails
# if it cannot be found.
#
# Usage (from any script that needs platform.sh):
#   _my_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${_my_dir}/source-platform.sh"

_source_platform_from() {
  local caller_dir="$1"
  local -a candidates=(
    "${caller_dir}/platform.sh"
    "${caller_dir}/../01-core/platform.sh"
    "/opt/scripts/core/platform.sh"
  )
  local c
  for c in "${candidates[@]}"; do
    if [ -f "${c}" ]; then
      # shellcheck disable=SC1090
      source "${c}"
      return 0
    fi
  done
  echo "FATAL: cannot find platform.sh (searched: ${candidates[*]})" >&2
  exit 1
}
