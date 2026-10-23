#!/usr/bin/env bash
[ -n "${_IMAGE_REF_ARGS_SH_LOADED:-}" ] && return 0
_IMAGE_REF_ARGS_SH_LOADED=1

image_ref_cli_args() {
  local -n _irca_tool="$1" _irca_ref="$2"
  shift 2
  if [ "$#" -eq 1 ]; then
    _irca_tool="${NERDCTL_BIN:-nerdctl}"
    _irca_ref="$1"
  else
    _irca_tool="$1"
    _irca_ref="$2"
  fi
}
