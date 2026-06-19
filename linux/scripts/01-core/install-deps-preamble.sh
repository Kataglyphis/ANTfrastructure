#!/usr/bin/env bash
# install-deps-preamble.sh - convenience preamble for install-deps scripts.
#
# Sources cross-env.sh (if available) and provides install_deps_preamble().
# The canonical definition lives in cross-apt.sh (sourced by cross-env.sh),
# but this file provides a fallback for older SDK images that lack it.
#
# Usage:
#   source /path/to/install-deps-preamble.sh
#   install_deps_preamble [extra_host_packages...]

[ -n "${_INSTALL_DEPS_PREAMBLE_LOADED:-}" ] && return 0
_INSTALL_DEPS_PREAMBLE_LOADED=1

if [ -f /opt/scripts/core/cross-env.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/cross-env.sh
fi

# Fallback: define install_deps_preamble if the SDK image's cross-apt.sh doesn't have it yet
if ! command -v install_deps_preamble >/dev/null 2>&1; then
  install_deps_preamble() {
    if command -v apt_update_smart >/dev/null 2>&1; then
      apt_update_smart
    else
      apt-get update -y
    fi
    if [ "$#" -gt 0 ]; then
      if command -v install_host_packages >/dev/null 2>&1; then
        install_host_packages "$@"
      else
        apt-get install -y --no-install-recommends "$@"
      fi
    fi
  }
fi
