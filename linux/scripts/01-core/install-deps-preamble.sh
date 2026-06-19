#!/usr/bin/env bash
# install-deps-preamble.sh - convenience loader for install-deps scripts that
# need the cross-env.sh + cross-apt.sh chain before calling install_deps_preamble().
#
# The canonical definition of install_deps_preamble() is in cross-apt.sh (sourced
# by cross-env.sh). This file provides a single-source convenience for scripts
# that want to load the entire chain in one go.
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
