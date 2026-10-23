# shellcheck shell=bash
# Sourcing cache policy must not initialize defaults or contact a server in standalone consumers.
_flag_disabled() {
  case "${1:-}" in
    0|false|FALSE|False|no|NO|off|OFF) return 0 ;;
    *) return 1 ;;
  esac
}

compiler_cache_stats_for_launcher() {
  case "$1" in
    *sccache*) sccache --show-stats 2>/dev/null | grep -E "$2" || true ;;
    *) ccache --show-stats 2>/dev/null | head -5 || true ;;
  esac
}

compiler_cache_guarded_launcher() {
  local directory="$1"
  for _scl in "${directory}/sccache-launcher.sh" /opt/scripts/core/sccache-launcher.sh; do
    if [ -x "${_scl}" ]; then
      printf '%s' "${_scl}"
      return 0
    fi
  done
  printf '%s' sccache
  return 0
}

compiler_cache_sccache_ready() {
  if [ "$1" = hook ]; then
    sccache_start_server || sccache --start-server >/dev/null 2>&1 || true
  else
    sccache --start-server >/dev/null 2>&1 || true
  fi
  sccache --show-stats >/dev/null 2>&1
}
