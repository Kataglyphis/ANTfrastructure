#!/usr/bin/env bash
# logging.sh - shared logging helpers
[ -n "${_LOGGING_SH_LOADED:-}" ] && return 0
_LOGGING_SH_LOADED=1
#
# Exposes:
#   info <msg...>
#   warn <msg...>
#   err  <msg...>   (exits 1)
#   log  <msg...>   (alias for info, kept for backwards compatibility)
#   die  <msg...>   (alias for err, kept for backwards compatibility)
#
# Color control:
#   LOG_COLOR=auto|always|never  (default: auto)
#   NO_COLOR disables colors (https://no-color.org/)

_log_color_mode() {
  printf '%s' "${LOG_COLOR:-auto}"
}

_log_use_color() {
  # NO_COLOR disables all colors
  if [ -n "${NO_COLOR:-}" ]; then
    return 1
  fi

  case "$(_log_color_mode)" in
    always) return 0 ;;
    never)  return 1 ;;
    auto|*)
      # Use color only when stdout is a TTY and TERM is not dumb
      [ -t 1 ] || return 1
      [ "${TERM:-}" != "dumb" ] || return 1
      return 0
      ;;
  esac
}

_log_prefix_plain() {
  case "$1" in
    INFO)  printf '%s' "[INFO]" ;;
    WARN)  printf '%s' "[WARN]" ;;
    ERROR) printf '%s' "[ERROR]" ;;
    *)     printf '%s' "[LOG]" ;;
  esac
}

_log_prefix_color() {
  # bold blue/yellow/red + reset
  case "$1" in
    INFO)  printf '%b' "\033[1;34m[INFO]\033[0m" ;;
    WARN)  printf '%b' "\033[1;33m[WARN]\033[0m" ;;
    ERROR) printf '%b' "\033[1;31m[ERROR]\033[0m" ;;
    *)     printf '%b' "\033[1m[LOG]\033[0m" ;;
  esac
}

_log_emit() {
  local level="$1"; shift
  local stream_fd="$1"; shift

  local prefix
  if _log_use_color; then
    prefix="$(_log_prefix_color "${level}")"
  else
    prefix="$(_log_prefix_plain "${level}")"
  fi

  # shellcheck disable=SC2059
  if [ "${stream_fd}" = "2" ]; then
    printf '%s %s\n' "${prefix}" "$*" >&2
  else
    printf '%s %s\n' "${prefix}" "$*"
  fi
}

info() { _log_emit INFO 1 "$@"; }
warn() { _log_emit WARN 2 "$@"; }
err()  { _log_emit ERROR 2 "$@"; exit 1; }

# Backwards compatible aliases
log() { info "$@"; }
die() { err "$@"; }

# Verification helpers: print PASS / FAIL / SKIP lines with LOG_COLOR awareness.
#
# IMPORTANT: The `fail()` here is DECORATIVE only — it prints FAIL but does NOT
# increment any FAILURES counter.  Verfication scripts (smoke-*, verify-*) MUST
# define their own local `fail()` that increments FAILURES, e.g.:
#   FAILURES=0
#   fail() { printf '  FAIL %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
# Or source 06-packaging/smoke-common.sh which already does this.
#
pass() {
  if _log_use_color; then
    printf '  \033[1;32mPASS\033[0m %s\n' "$*"
  else
    printf '  PASS %s\n' "$*"
  fi
}

fail() {
  if _log_use_color; then
    printf '  \033[1;31mFAIL\033[0m %s\n' "$*" >&2
  else
    printf '  FAIL %s\n' "$*" >&2
  fi
}

skip() {
  printf '  SKIP %s\n' "$*"
}

_install_trap() {
  local action="${1:-err}"
  on_err() {
    local line="${1:-?}"
    local cmd="${2:-?}"
    "${action}" "Command failed (line ${line}): ${cmd}"
  }
  trap 'on_err "${LINENO}" "${BASH_COMMAND}"' ERR
}
install_err_trap()  { _install_trap err; }
install_warn_trap() { _install_trap warn; }

# ── Sudo guard ────────────────────────────────────────────────────────────────
# Canonical sudo-guard core. Populates BOTH SUDO_WRAP and SUDO to "sudo" (when
# not root and sudo is available) or "" (when root), so callers of either
# ensure_sudo_or_die (reads SUDO_WRAP) or require_sudo (reads SUDO) get a valid
# wrapper. Dies with the provided message when non-root and sudo is missing.
#
# Usage: _ensure_sudo_wrapper [die-message]
# shellcheck disable=SC2034  # SUDO_WRAP and SUDO are consumed by external callers
_ensure_sudo_wrapper() {
  local die_msg="${1:-This command requires sudo or root. Install sudo or run as root.}"
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      SUDO_WRAP="sudo"
      SUDO="sudo"
    else
      die "${die_msg}"
    fi
  else
    SUDO_WRAP=""
    SUDO=""
  fi
}

# Ensure we can run privileged commands.  Sets SUDO_WRAP="sudo" or SUDO_WRAP=""
# depending on EUID.  Exits if no sudo is available and we are not root.
#
# Usage: ensure_sudo_or_die
ensure_sudo_or_die() {
  _ensure_sudo_wrapper "This command requires sudo or root. Install sudo or run as root."
}

retry() {
  local max_attempts="${1:-3}"
  local sleep_sec="${2:-5}"
  local description="${3:-operation}"
  shift 3 || true
  local attempt=0

  while true; do
    attempt=$((attempt + 1))
    if "$@"; then
      return 0
    fi
    if [ "${attempt}" -ge "${max_attempts}" ]; then
      printf '[ERROR] %s failed after %d attempts\n' "${description}" "${attempt}" >&2
      return 1
    fi
    printf '[WARN] %s attempt %d/%d failed; retrying in %ds...\n' "${description}" "${attempt}" "${max_attempts}" "${sleep_sec}" >&2
    sleep "${sleep_sec}"
  done
}
