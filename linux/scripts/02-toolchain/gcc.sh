#!/usr/bin/env bash
# gcc.sh - GCC toolchain

gcc_reported_version() {
  local tool="$1"
  local version=""

  command -v "$tool" >/dev/null 2>&1 || return 1
  version="$("$tool" -dumpfullversion -dumpversion 2>/dev/null || true)"
  version="${version%%[[:space:]]*}"
  [ -n "${version}" ] || return 1
  printf '%s' "${version}"
}

install_cross_gcc_sysroot_packages() {
  local normalized_target="$1"
  local triplet

  normalized_target="$(arch_normalize "${normalized_target}")"
  triplet="$(arch_deb_multiarch_triplet_for "${normalized_target}")" || die "Unsupported cross target: ${normalized_target}"

  case "${normalized_target}" in
    amd64)
      apt_install_available \
        binutils-x86-64-linux-gnu
      ;;
    arm64)
      apt_install_available \
        binutils-aarch64-linux-gnu \
        libc6-dev-arm64-cross \
        linux-libc-dev-arm64-cross
      ;;
    riscv64)
      apt_install_available \
        binutils-riscv64-linux-gnu \
        libc6-dev-riscv64-cross \
        linux-libc-dev-riscv64-cross
      ;;
    *)
      die "Unsupported cross target: ${normalized_target}"
      ;;
  esac

  if [ "${normalized_target}" != "amd64" ]; then
    [ -d "/usr/${triplet}/include" ] || die "Expected cross headers not found: /usr/${triplet}/include"
    [ -d "/usr/${triplet}/lib" ] || die "Expected cross libs not found: /usr/${triplet}/lib"
    log "Prepared cross sysroot packages for ${normalized_target}: /usr/${triplet}"
  fi

  [ -x "/usr/bin/${triplet}-as" ] || die "Expected cross binutils not found: /usr/bin/${triplet}-as"
}

stage_cross_gcc_sysroot_libs() {
  local prefix="$1"
  local triplet="$2"
  local src_dir="/usr/${triplet}/lib"
  local dst_dir="${prefix}/${triplet}/lib"
  local entry base

  [ -d "${src_dir}" ] || return 0

  $SUDO mkdir -p "${dst_dir}"
  for entry in "${src_dir}"/*; do
    [ -e "${entry}" ] || continue
    base="$(basename "${entry}")"
    if [ ! -e "${dst_dir}/${base}" ]; then
      $SUDO ln -sfn "${entry}" "${dst_dir}/${base}"
    fi
  done
  log "Staged target sysroot libs for ${triplet} into ${dst_dir}"
}

build_source_cross_gcc_targets() {
  local full_version="$1"
  local targets_raw="${CROSS_TARGETS:-amd64,arm64,riscv64}"
  local gcc_major="$(version_major "${full_version}")"
  local prefix="/opt/gcc-${full_version}"
  local script_dir builder
  local requested_major="${gcc_major}"
  local target normalized_target triplet compat_prefix tool actual_tool actual_version

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  builder="${script_dir}/build-gcc.sh"
  [ -f "${builder}" ] || die "GCC build script not found: ${builder}"
  chmod +x "${builder}" || true
  targets_raw="$(arch_list_csv_normalize "${targets_raw}")" || die "Unsupported GCC cross target list: ${targets_raw}"

  log "Building host GCC ${full_version} from source for cross mode"
  PREFIX="${prefix}" \
    BUILD_DIR="${HOME}/tmp2/gcc-build-${full_version}-native" \
    JOBS="${JOBS:-$(nproc)}" \
    bash "${builder}" --version "${full_version}"

  log "Building cross GCC toolchains from source for ${targets_raw}"
  for target in ${targets_raw//,/ }; do
    normalized_target="$(arch_normalize "$target")"
    case "${normalized_target}" in
      amd64|arm64|riscv64) ;;
      *) die "Unsupported cross target: ${target}" ;;
    esac
    install_cross_gcc_sysroot_packages "${normalized_target}"

    triplet="$(arch_deb_multiarch_triplet_for "${normalized_target}")" || die "Unsupported cross target: ${normalized_target}"
    if [ "${normalized_target}" = "amd64" ]; then
      for tool in gcc g++ gcov; do
        [ -x "${prefix}/bin/${tool}" ] || die "Expected host GCC tool not found: ${prefix}/bin/${tool}"
      done
      $SUDO ln -sfn "${prefix}/bin/gcc" "${prefix}/bin/${triplet}-gcc"
      $SUDO ln -sfn "${prefix}/bin/g++" "${prefix}/bin/${triplet}-g++"
      $SUDO ln -sfn "${prefix}/bin/cpp" "${prefix}/bin/${triplet}-cpp"
      $SUDO ln -sfn "${prefix}/bin/gcov" "${prefix}/bin/${triplet}-gcov"
      $SUDO ln -sfn "${prefix}/bin/gcc-ar" "${prefix}/bin/${triplet}-gcc-ar"
      $SUDO ln -sfn "${prefix}/bin/gcc-nm" "${prefix}/bin/${triplet}-gcc-nm"
      $SUDO ln -sfn "${prefix}/bin/gcc-ranlib" "${prefix}/bin/${triplet}-gcc-ranlib"
      for tool in as ld ar nm ranlib strip objcopy; do
        command -v "${triplet}-${tool}" >/dev/null 2>&1 || die "Expected cross binutils not found: ${triplet}-${tool}"
        $SUDO ln -sfn "$(command -v ${triplet}-${tool})" "${prefix}/bin/${triplet}-${tool}"
      done
    else
      stage_cross_gcc_sysroot_libs "${prefix}" "${triplet}"
      log "Building source cross GCC ${full_version} for ${triplet}"
      PREFIX="${prefix}" \
        BUILD_DIR="${HOME}/tmp2/gcc-build-${full_version}-${triplet}" \
        JOBS="${JOBS:-$(nproc)}" \
        bash "${builder}" \
          --version "${full_version}" \
          --target "${triplet}" \
          --languages c,c++ \
          --sysroot / \
          --native-system-header-dir "/usr/${triplet}/include" \
          --disable-bootstrap \
          --skip-system-registration

      for tool in gcc g++ gcc-ar gcc-nm gcc-ranlib; do
        [ -x "${prefix}/bin/${triplet}-${tool}" ] || die "Expected cross GCC tool not found: ${prefix}/bin/${triplet}-${tool}"
      done
      [ -x "${prefix}/bin/${triplet}-cpp" ] || true
      for tool in as ld ar nm ranlib strip objcopy; do
        command -v "${triplet}-${tool}" >/dev/null 2>&1 || die "Expected cross binutils not found: ${triplet}-${tool}"
        $SUDO ln -sfn "$(command -v ${triplet}-${tool})" "${prefix}/bin/${triplet}-${tool}"
      done
      stage_cross_gcc_sysroot_libs "${prefix}" "${triplet}"

      # Canadian cross: build a native GCC for the target architecture
      # (host triplet == target triplet). The resulting gcc binary runs
      # natively on the target architecture and produces target-arch code.
      # Uses the just-built cross compiler to cross-compile GCC itself.
      # Skip when SKIP_CANADIAN_CROSS is set (host may lack target sysroot).
      if [ "${SKIP_CANADIAN_CROSS:-0}" = "1" ]; then
        log "Skipping Canadian cross for ${normalized_target} (SKIP_CANADIAN_CROSS=1)"
        return 0
      fi
      local native_prefix="/opt/gcc-${full_version}-native-${normalized_target}"
      local cross_cc="${prefix}/bin/${triplet}-gcc"
      local cross_cxx="${prefix}/bin/${triplet}-g++"
      [ -x "${cross_cc}" ] || die "Cross compiler ${cross_cc} not found for Canadian cross"
      [ -x "${cross_cxx}" ] || die "Cross compiler ${cross_cxx} not found for Canadian cross"
      log "Building native GCC ${full_version} for ${normalized_target} (Canadian cross via ${cross_cc})"
      CC="${cross_cc}" CXX="${cross_cxx}" \
        PREFIX="${native_prefix}" \
        BUILD_DIR="${HOME}/tmp2/gcc-build-${full_version}-native-${normalized_target}" \
        JOBS="${JOBS:-$(nproc)}" \
        bash "${builder}" \
          --version "${full_version}" \
          --target "${triplet}" \
          --host "${triplet}" \
          --languages c,c++ \
          --sysroot / \
          --native-system-header-dir "/usr/${triplet}/include" \
          --disable-bootstrap \
          --skip-system-registration

      [ -x "${native_prefix}/bin/gcc" ] || die "Expected native GCC not found: ${native_prefix}/bin/gcc"
      [ -x "${native_prefix}/bin/g++" ] || die "Expected native G++ not found: ${native_prefix}/bin/g++"
      log "Installed native GCC ${full_version} for ${normalized_target} at ${native_prefix}"
    fi

    for tool in gcc g++ ar; do
      [ -x "${prefix}/bin/${triplet}-${tool}" ] || die "Expected cross compiler not found: ${prefix}/bin/${triplet}-${tool}"
    done
    log "Installed cross compiler commands for ${normalized_target}: ${triplet}-gcc ${triplet}-g++ ${triplet}-ar"

    actual_tool="${prefix}/bin/${triplet}-g++"
    actual_version="$(gcc_reported_version "${actual_tool}" || true)"
    if [ -n "${actual_version}" ]; then
      if [ -n "${requested_major}" ] && [ "$(version_major "${actual_version}")" != "${requested_major}" ]; then
        warn "Cross mode requested GCC ${full_version}, but ${triplet}-g++ resolves to ${actual_tool} (GCC ${actual_version})."
      else
        log "Cross compiler version for ${normalized_target}: ${actual_tool} (${actual_version})"
      fi
    fi
  done

  compat_prefix="/opt/gcc-${full_version}"
  if [ ! -d "${compat_prefix}/bin" ]; then
    die "Expected GCC install prefix not found after cross build: ${compat_prefix}/bin"
  fi
}

install_gcc() {
  log "Installing GCC ${GCC_WANTED}"

  local gcc_major="$(version_major "${GCC_WANTED}")"
  local default_full_version
  case "${gcc_major}" in
    16) default_full_version="16.1.0" ;;
    15) default_full_version="15.2.0" ;;
    *) default_full_version="${gcc_major}.1.0" ;;
  esac
  local full_version="${GCC_VERSION:-${default_full_version}}"

  # In cross mode, keep the host compiler native and install target-specific
  # GNU toolchains under their triplet names (for example aarch64-linux-gnu-gcc).
  if cross_mode_requested; then
    if [[ ! "${full_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      full_version="${default_full_version}"
    fi

    build_source_cross_gcc_targets "${full_version}"
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
