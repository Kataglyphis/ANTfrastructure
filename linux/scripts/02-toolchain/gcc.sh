#!/usr/bin/env bash
# gcc.sh - GCC toolchain

install_gcc() {
  log "Installing GCC ${GCC_WANTED}"

  local gcc_major="${GCC_WANTED%%.*}"
  if [ -n "${gcc_major}" ] && [ "${gcc_major}" -ge 15 ] 2>/dev/null; then
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local builder="${script_dir}/build-and-make-default-gcc15.sh"
    if [ ! -f "${builder}" ]; then
      die "GCC ${GCC_WANTED} requested, but ${builder} not found."
    fi
    chmod +x "${builder}" || true
    # Allow override of exact GCC 15.x version via env; default is in the script.
    GCC_VERSION="${GCC_VERSION:-15.2.0}" \
      PREFIX="${PREFIX:-/opt/gcc-${GCC_VERSION}}" \
      BUILD_DIR="${BUILD_DIR:-${HOME}/tmp2/gcc-build-${GCC_VERSION}}" \
      JOBS="${JOBS:-$(nproc)}" \
      bash "${builder}"
    return 0
  fi

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