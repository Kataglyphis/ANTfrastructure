#!/usr/bin/env bash
# tool-checks.sh - "is this command on PATH, and die naming every missing one".

# docs/shared-script-libraries.md#tool-presence-01-coretool-checkssh

# Each definition yields to one the caller already has, so sourcing this never clobbers a consumer's own.
[ -n "${_TOOL_CHECKS_SH_LOADED:-}" ] && return 0
_TOOL_CHECKS_SH_LOADED=1

if ! declare -F has_tool >/dev/null 2>&1; then
  has_tool() { command -v "$1" >/dev/null 2>&1; }
fi

# Name every missing tool at once; reporting only the first costs one failed run per tool.
if ! declare -F require_tools >/dev/null 2>&1; then
  require_tools() {
    local missing=() tool
    for tool in "$@"; do
      command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
      err "Required tools not found: ${missing[*]}"
    fi
  }
fi
