#!/usr/bin/env bash
# cmake.sh - CMake from Kitware

install_cmake() {
  log "Installing latest CMake from Kitware repo"
  $SUDO apt-get purge --auto-remove -y cmake || true
  add_kitware_repo
  apt_install cmake
  cmake --version || true
}