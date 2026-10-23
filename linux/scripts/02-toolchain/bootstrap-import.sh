#!/usr/bin/env bash
# Functions-only imports need explicit status handling when callers source conditionally.
# shellcheck source=bootstrap.sh
source "$(dirname "${BASH_SOURCE[0]}")/bootstrap.sh" || return "$?"
declare -F source_toolchain_required >/dev/null || {
  printf 'ERROR: bootstrap.sh does not provide source_toolchain_required\n' >&2
  return 1
}
