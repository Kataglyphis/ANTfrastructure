#!/usr/bin/env bash
# The only resolver of 01-core/logging.sh and the fallbacks for lib/*.sh. docs/shared-script-libraries.md#the-logging-bootstrap
_log_bootstrap_register_fallback() {
  local name="$1" style="$2" label color redirect='' fatal='' format definition
  case "${name}" in
    info|log) label=INFO; color=34 ;;
    warn) label=WARN; color=33; redirect=' >&2' ;;
    err) label=ERROR; color=31; redirect=' >&2'; fatal=' exit 1;' ;;
    *) return 2 ;;
  esac
  format="[${label}] %s\\n"
  if [ "${style}" = color ]; then format="\\033[1;${color}m[${label}]\\033[0m %s\\n"; fi
  printf -v definition '%s() { printf %q "$*"%s;%s }' "${name}" "${format}" "${redirect}" "${fatal}"
  eval "${definition}"
}

log_bootstrap_fallbacks() {
  local lookup="$1" style="$2" name
  local -a probe
  case "${lookup}" in
    command) probe=(command -v) ;;
    function) probe=(declare -F) ;;
    *) return 2 ;;
  esac
  shift 2
  for name in "$@"; do
    "${probe[@]}" "${name}" >/dev/null 2>&1 && continue
    _log_bootstrap_register_fallback "${name}" "${style}" || return $?
  done
  return 0
}

# Standalone build scripts need only the fallback registrar, without importing the real logger.
if [ "${_LOG_BOOTSTRAP_REGISTRAR_ONLY:-0}" = 1 ]; then return 0; fi
[ -n "${_LOG_BOOTSTRAP_SH_LOADED:-}" ] && return 0
_LOG_BOOTSTRAP_SH_LOADED=1

_LOG_BOOTSTRAP_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../01-core"
if ! declare -F info >/dev/null 2>&1; then
  if [[ -f "${_LOG_BOOTSTRAP_CORE_DIR}/logging.sh" ]]; then
    # shellcheck source=../01-core/logging.sh
    source "${_LOG_BOOTSTRAP_CORE_DIR}/logging.sh"
  fi
fi
log_bootstrap_fallbacks function color info warn err
