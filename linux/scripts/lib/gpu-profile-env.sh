#!/usr/bin/env bash
# Run GPU verification without inheriting MIGraphX tuning overrides.

gpu_without_migraphx_overrides() {
  local name
  local -a unset_args=()
  for name in "${!ORT_MIGRAPHX_@}" "${!MIGRAPHX_@}"; do
    [[ -z "$name" ]] || unset_args+=(-u "$name")
  done
  env "${unset_args[@]}" "$@"
}
