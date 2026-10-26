# shellcheck shell=bash
# Sourced by the runtime lane libraries; sets no shell options.
[ -n "${_LIB_RUNTIME_SWITCH_SH_LOADED:-}" ] && return 0
_LIB_RUNTIME_SWITCH_SH_LOADED=1

# runtime_switch_mode <var> <default> <word-1> <word-0> <meaning-1> <meaning-0>: an unknown value is rc 2, so a typo stops a lane at its start.
runtime_switch_mode() {
  local value="${!1:-$2}"
  case "${value}" in
    1) printf '%s' "$3" ;;
    0) printf '%s' "$4" ;;
    *)
      printf '[ERROR] %s=%s: expected 1 (%s) or 0 (%s)\n' "$1" "${value}" "$5" "$6" >&2
      return 2
      ;;
  esac
}
