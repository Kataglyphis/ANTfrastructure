#!/usr/bin/env bash
# gcc.sh - GCC toolchain

install_gcc() {
  log "Installing GCC ${GCC_WANTED}"
  apt_install gcc-"${GCC_WANTED}" g++-"${GCC_WANTED}" gfortran-"${GCC_WANTED}"
  for t in gcc g++ gcov; do
    if [ -x "/usr/bin/${t}-${GCC_WANTED}" ]; then
      $SUDO update-alternatives --install "/usr/bin/${t}" "${t}" "/usr/bin/${t}-${GCC_WANTED}" 100
      $SUDO update-alternatives --set "${t}" "/usr/bin/${t}-${GCC_WANTED}"
    fi
  done
  gcc --version || true
  g++ --version || true
}