#!/usr/bin/env bash
# Resolve sibling paths before argument validation without importing the build framework early.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return
source "${SCRIPT_DIR}/../../../lib/cli-value-options.sh"
cli_require_positionals "$1" "$2" "$2" "${@:3}" || return
work="$3"
[[ -n "${work}" ]] || { printf 'Work root must not be empty\n' >&2; return 2; }
