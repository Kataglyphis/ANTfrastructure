#!/usr/bin/env bash
# core.sh - base packages
#
# Depends on logging.sh (log) and common.sh (apt_install) which must be
# sourced by the caller before calling install_core_tools().

install_core_tools() {
  log "Installing core tools"
  apt_install sudo curl ca-certificates gnupg wget xz-utils git
  apt_install dpkg-dev fakeroot binutils binutils-dev
  apt_install build-essential ninja-build make sccache ccache
  apt_install graphviz doxygen gcovr
}