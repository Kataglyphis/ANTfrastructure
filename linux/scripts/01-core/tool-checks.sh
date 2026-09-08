#!/usr/bin/env bash
# tool-checks.sh - "is this command on PATH, and die naming every missing one".

# The one owner of a pair that had no canonical home and was therefore written
# three times: lib/code-quality.sh:18-27 and lib/coverage.sh:38-45 each carried
# an inline `if ! declare -F ... fi` fallback, and BeschleunigerBallett's
# scripts/linux/lib/common.sh a third copy.
#
#   has_tool <cmd>            0 when <cmd> is on PATH
#   require_tools <cmd>...    die naming EVERY missing one, not just the first
#
# docs/shared-script-libraries.md

# Each definition is guarded by `declare -F` rather than by the file-level load
# guard alone: a consumer whose own common.sh already defines these keeps its
# version, which is the behaviour the two inline fallbacks had and the reason
# they were written that way. Sourcing this file never clobbers a caller.
[ -n "${_TOOL_CHECKS_SH_LOADED:-}" ] && return 0
_TOOL_CHECKS_SH_LOADED=1

if ! declare -F has_tool >/dev/null 2>&1; then
  has_tool() { command -v "$1" >/dev/null 2>&1; }
fi

# Naming every missing tool at once is the whole point: reporting only the first
# turns "install these four" into four failed runs.
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
