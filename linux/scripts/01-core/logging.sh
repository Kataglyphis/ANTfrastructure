#!/usr/bin/env bash
# logging.sh - shared logging helpers
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
