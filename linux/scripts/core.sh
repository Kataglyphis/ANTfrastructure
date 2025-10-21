#!/usr/bin/env bash
# core.sh - base packages

install_core_tools() {
  log "Installing core tools"
  apt_install sudo curl ca-certificates gnupg wget xz-utils git
  apt_install dpkg-dev fakeroot binutils
  apt_install build-essential ninja-build make sccache ccache
  apt_install graphviz doxygen gcovr
}