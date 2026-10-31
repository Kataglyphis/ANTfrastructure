#!/usr/bin/env bash
# Run GPU verification without inheriting MIGraphX tuning overrides.

# shellcheck source=./log-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/log-bootstrap.sh"

gpu_without_migraphx_overrides() {
  local name
  local -a unset_args=()
  for name in "${!ORT_MIGRAPHX_@}" "${!MIGRAPHX_@}"; do
    [[ -z "$name" ]] || unset_args+=(-u "$name")
  done
  env "${unset_args[@]}" "$@"
}
