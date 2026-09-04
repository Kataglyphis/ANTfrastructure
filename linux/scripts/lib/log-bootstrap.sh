#!/usr/bin/env bash
# log-bootstrap.sh - the one owner of the lib/ logging bootstrap.
#
# Sourced first by every other lib/*.sh; it is the only file here that resolves
# 01-core/logging.sh, and the only place the minimal fallbacks live.
# docs/shared-script-libraries.md#the-logging-bootstrap
[ -n "${_LOG_BOOTSTRAP_SH_LOADED:-}" ] && return 0
_LOG_BOOTSTRAP_SH_LOADED=1

_LOG_BOOTSTRAP_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../01-core"
if ! declare -F info >/dev/null 2>&1; then
  if [[ -f "${_LOG_BOOTSTRAP_CORE_DIR}/logging.sh" ]]; then
    # shellcheck source=../01-core/logging.sh
    source "${_LOG_BOOTSTRAP_CORE_DIR}/logging.sh"
  fi
fi
if ! declare -F info >/dev/null 2>&1; then
  info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
fi
if ! declare -F warn >/dev/null 2>&1; then
  warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
fi
if ! declare -F err >/dev/null 2>&1; then
  err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
fi
