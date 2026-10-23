# shellcheck shell=bash
# Shared cache policy stays free of environment defaults and server startup so standalone consumers can source it safely.
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
