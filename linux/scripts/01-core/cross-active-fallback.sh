#!/usr/bin/env bash
# Registration binds the fallback choice while callback names remain replaceable.
register_cross_active_fallback() {
  case "${1:-}" in
    core|native) ;;
    *) printf 'ERROR: register_cross_active_fallback requires core or native\n' >&2; return 2 ;;
  esac
  if ! command -v cross_build_is_active >/dev/null 2>&1; then
    case "$1" in
      native) cross_build_is_active() { false; } ;;
      core)
        if command -v cross_build_enabled >/dev/null 2>&1; then
          cross_build_is_active() { cross_build_enabled; }
        else
          cross_build_is_active() { core_cross_build_is_active; }
        fi ;;
    esac
  fi
}
