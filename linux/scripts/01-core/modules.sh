#!/usr/bin/env bash
# modules.sh - shared module loader
#
# Provides: source_module <filename>
#           source_modules_framework
#
# Supports both repository layout:
#   linux/scripts/01-core, 02-toolchain, ...
# and container layout:
#   /opt/scripts/core, /opt/scripts/toolchain

_find_scripts_root() {
  local start_dir="$1"
  local d="$start_dir"
  while [ "$d" != "/" ] && [ "$d" != "." ] && [ -n "$d" ]; do
    if [ -d "$d/01-core" ] || [ -d "$d/core" ]; then
      printf '%s' "$d"
      return 0
    fi
    d="$(dirname "$d")"
  done
  return 1
}

source_modules_framework() {
  local caller_dir="${1:-${SCRIPT_DIR:-}}"

  if [ -z "${caller_dir}" ]; then
    caller_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  fi

  if [ -z "${SCRIPT_DIR:-}" ]; then
    export SCRIPT_DIR="${caller_dir}"
  fi

  if [ -z "${SCRIPTS_ROOT:-}" ]; then
    local root
    root="$(_find_scripts_root "${caller_dir}")" || true
    if [ -n "${root}" ]; then
      export SCRIPTS_ROOT="${root}"
    fi
  fi
}

source_module() {
  local name="$1"

  if [ -z "${name}" ]; then
    echo "Error: source_module requires a filename" >&2
    return 1
  fi

  local caller_dir="${SCRIPT_DIR:-}"
  if [ -z "${caller_dir}" ]; then
    caller_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  fi

  local -a candidates=(
    "${caller_dir}/${name}"
    "${caller_dir}/../01-core/${name}"
    "${caller_dir}/../02-toolchain/${name}"
    "/opt/scripts/core/${name}"
    "/opt/scripts/toolchain/${name}"
  )

  if [ -n "${SCRIPTS_ROOT:-}" ] && [ "${SCRIPTS_ROOT}" != "${caller_dir}" ]; then
    candidates+=(
      "${SCRIPTS_ROOT}/01-core/${name}"
      "${SCRIPTS_ROOT}/02-toolchain/${name}"
    )
  fi

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
