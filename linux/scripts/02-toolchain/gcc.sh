#!/usr/bin/env bash
# gcc.sh - GCC toolchain

install_gcc() {
  log "Installing GCC ${GCC_WANTED}"

  local gcc_major="${GCC_WANTED%%.*}"
  local gcc_minor="${GCC_WANTED#*.}"
  local gcc_patch="${GCC_VERSION:-${gcc_minor}}"
  
  # For GCC >= 15, build from source (no apt packages available)
  if [ -n "${gcc_major}" ] && [ "${gcc_major}" -ge 15 ] 2>/dev/null; then
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local builder="${script_dir}/build-gcc.sh"
    if [ ! -f "${builder}" ]; then
      die "GCC build script not found: ${builder}"
    fi
    chmod +x "${builder}" || true
    
    # Determine full version (e.g., 15.2.0 from GCC_WANTED=15)
    local full_version="${GCC_VERSION:-${gcc_major}.${gcc_patch:-2.0}}"
    if [[ ! "${full_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      full_version="${gcc_major}.2.0"
    fi
    
    log "Building GCC ${full_version} from source..."
    PREFIX="${PREFIX:-/opt/gcc-${full_version}}" \
      BUILD_DIR="${BUILD_DIR:-${HOME}/tmp2/gcc-build-${full_version}}" \
      JOBS="${JOBS:-$(nproc)}" \
      bash "${builder}" --version "${full_version}"
    return 0
  fi

  # For GCC < 15, install from apt
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