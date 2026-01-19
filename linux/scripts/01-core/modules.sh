#!/usr/bin/env bash
# modules.sh - shared module loader
#
# Provides: source_module <filename>
#
# Supports both repository layout:
#   linux/scripts/01-core, 02-toolchain, ...
# and container layout:
#   /opt/scripts/core, /opt/scripts/toolchain

source_module() {
  local name="$1"

  if [ -z "${name}" ]; then
    echo "Error: source_module requires a filename" >&2
    return 1
  fi

  # Prefer caller-provided SCRIPT_DIR; otherwise derive from call stack.
  local caller_dir="${SCRIPT_DIR:-}"
  if [ -z "${caller_dir}" ]; then
    # BASH_SOURCE[0] is this file; BASH_SOURCE[1] is the caller.
    caller_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  fi

  local candidates=(
    "${caller_dir}/${name}"
    "${caller_dir}/../01-core/${name}"
    "${caller_dir}/../02-toolchain/${name}"
    "/opt/scripts/core/${name}"
    "/opt/scripts/toolchain/${name}"
  )

  local c
  for c in "${candidates[@]}"; do
    if [ -f "${c}" ]; then
      # shellcheck disable=SC1090
      source "${c}"
      return 0
    fi
  done

  echo "Error: required module '${name}' not found (searched: ${candidates[*]})" >&2
  return 1
}
