#!/usr/bin/env bash
# gcc.sh - GCC toolchain

gcc_apt_has_package() {
  local pkg="$1"
  apt-cache show "$pkg" >/dev/null 2>&1
}

gcc_apt_install_available() {
  local pkgs=()
  local pkg

  for pkg in "$@"; do
    if gcc_apt_has_package "$pkg"; then
      pkgs+=("$pkg")
    else
      log "Skipping missing package: ${pkg}"
    fi
  done

  if [ "${#pkgs[@]}" -gt 0 ]; then
    apt_install "${pkgs[@]}"
  fi
}

gcc_cross_triplet() {
  case "$1" in
    arm64|aarch64) printf '%s' "aarch64-linux-gnu" ;;
    riscv64) printf '%s' "riscv64-linux-gnu" ;;
    amd64|x86_64) printf '%s' "x86_64-linux-gnu" ;;
    *) return 1 ;;
  esac
}

install_cross_gcc_targets() {
  local full_version="$1"
  local targets_raw="${CROSS_TARGETS:-amd64,arm64,riscv64}"
  local target triplet compat_prefix

  log "Installing cross GCC toolchains for ${targets_raw}"
  for target in ${targets_raw//,/ }; do
    case "$target" in
      arm64|aarch64)
        gcc_apt_install_available \
          binutils-aarch64-linux-gnu \
          gcc-aarch64-linux-gnu \
          g++-aarch64-linux-gnu \
          cpp-aarch64-linux-gnu \
          libc6-dev-arm64-cross \
          linux-libc-dev-arm64-cross
        ;;
      riscv64)
        gcc_apt_install_available \
          binutils-riscv64-linux-gnu \
          gcc-riscv64-linux-gnu \
          g++-riscv64-linux-gnu \
          cpp-riscv64-linux-gnu \
          libc6-dev-riscv64-cross \
          linux-libc-dev-riscv64-cross
        ;;
      amd64|x86_64)
        log "Skipping cross compiler install for host target ${target}"
        continue
        ;;
      *)
        die "Unsupported cross target: ${target}"
        ;;
    esac

    triplet="$(gcc_cross_triplet "$target")" || die "Unsupported cross target: ${target}"
    command -v "${triplet}-gcc" >/dev/null 2>&1 || die "Expected cross compiler not found: ${triplet}-gcc"
    log "Installed cross compiler: ${triplet}-gcc"
  done

  compat_prefix="/opt/gcc-${full_version}"
  if [ -e "${compat_prefix}" ] && [ ! -L "${compat_prefix}" ]; then
    warn "Compatibility prefix already exists and is not a symlink: ${compat_prefix}"
    return 0
  fi

  $SUDO mkdir -p /opt
  $SUDO ln -sfn /usr "${compat_prefix}"
  log "Created compatibility GCC prefix for cross mode: ${compat_prefix} -> /usr"
}

install_gcc() {
  log "Installing GCC ${GCC_WANTED}"

  local gcc_major="${GCC_WANTED%%.*}"
  local default_full_version
  case "${gcc_major}" in
    16) default_full_version="16.1.0" ;;
    15) default_full_version="15.2.0" ;;
    *) default_full_version="${gcc_major}.2.0" ;;
  esac
  local full_version="${GCC_VERSION:-${default_full_version}}"

  # In cross mode, keep the host compiler native and install target-specific
  # GNU toolchains under their triplet names (for example aarch64-linux-gnu-gcc).
  if [ "${BUILD_MODE:-native}" = "cross" ]; then
    if [[ ! "${full_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      full_version="${default_full_version}"
    fi

    install_cross_gcc_targets "${full_version}"
    gcc --version || true
    return 0
  fi
  
  # For GCC >= 15, build from source (no apt packages available)
  if [ -n "${gcc_major}" ] && [ "${gcc_major}" -ge 15 ] 2>/dev/null; then
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local builder="${script_dir}/build-gcc.sh"
    if [ ! -f "${builder}" ]; then
      die "GCC build script not found: ${builder}"
    fi
    chmod +x "${builder}" || true
    
    # Determine full version (e.g., 16.1.0 from GCC_WANTED=16)
    if [[ ! "${full_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      full_version="${default_full_version}"
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
