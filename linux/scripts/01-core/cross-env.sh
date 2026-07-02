#!/usr/bin/env bash
# cross-env.sh - shared helpers for amd64-hosted target builds
[ -n "${_CROSS_ENV_SH_LOADED:-}" ] && return 0
_CROSS_ENV_SH_LOADED=1

_CROSS_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CROSS_ENV_APT_UPDATED="${_CROSS_ENV_APT_UPDATED:-0}"

# shellcheck disable=SC1090,SC1091
[ -f "${_CROSS_ENV_DIR}/platform.sh" ] && source "${_CROSS_ENV_DIR}/platform.sh"
# shellcheck disable=SC1090,SC1091
[ -f "${_CROSS_ENV_DIR}/ubuntu-mirror.sh" ] && source "${_CROSS_ENV_DIR}/ubuntu-mirror.sh"

cross_foreign_arch_ports_mirror_url() {
  local archive_url explicit_ports_url

  explicit_ports_url="${FAST_UBUNTU_PORTS_MIRROR_URL:-${UBUNTU_PORTS_MIRROR_URL:-}}"
  if ubuntu_mirror_is_truthy "${USE_FAST_UBUNTU_MIRROR:-false}"; then
    archive_url="${FAST_UBUNTU_MIRROR_URL:-$(ubuntu_default_archive_mirror_url)}"
    ubuntu_effective_ports_mirror_url "${archive_url}" "${explicit_ports_url}"
    return 0
  fi

  ubuntu_mirror_normalize_url "${explicit_ports_url:-$(ubuntu_default_ports_mirror_url)}"
}

cross_mode_requested() {
  [ "${BUILD_MODE:-native}" = "cross" ]
}

cross_target_is_foreign() {
  [ "$(build_arch_oci)" != "$(arch_oci)" ]
}

cross_build_enabled() {
  cross_mode_requested || return 1
  cross_target_is_foreign
}

# Compatibility alias used by media build scripts.
is_cross() { cross_build_enabled; }

# All-purpose cross-build guard used by 60+ media/toolchain/framework scripts.
cross_build_is_active() { cross_build_enabled; }

cross_target_arch() {
  arch_oci
}

cross_build_arch() {
  build_arch_oci
}

cross_require_single_target_arch() {
  local raw="${1:-${TARGET_ARCH:-${TARGETARCH:-${ARCH:-}}}}"
  local scope="${2:-cross build}"
  local target_arch=""

  [ -n "${raw}" ] || {
    printf 'TARGET_ARCH is required for %s\n' "${scope}" >&2
    return 1
  }

  case "${raw}" in
    *,*)
      printf 'TARGET_ARCH must be a single architecture for %s: %s\n' "${scope}" "${raw}" >&2
      return 1
      ;;
  esac

  target_arch="$(canonical_target_arch "${raw}" 2>/dev/null || true)"
  case "${target_arch}" in
    amd64|arm64|386|riscv64)
      printf '%s' "${target_arch}"
      return 0
      ;;
  esac

  printf 'Unsupported TARGET_ARCH=%s\n' "${raw}" >&2
  return 1
}

cross_set_target_env() {
  local target_arch=""

  target_arch="$(cross_require_single_target_arch "${1:-${TARGET_ARCH:-${TARGETARCH:-${ARCH:-}}}}" "${2:-cross build}")" || return 1
  export TARGET_ARCH="${target_arch}"
  export TARGETARCH="${target_arch}"
  export TARGETPLATFORM="linux/${target_arch}"
}

prepare_cross_target_env() {
  local scope="${2:-cross build}"

  cross_set_target_env "${1:-${TARGET_ARCH:-${TARGETARCH:-${ARCH:-}}}}" "${scope}" || return 1
  if cross_build_enabled; then
    install_cross_bin_symlinks "${TARGET_ARCH}"
  fi
  setup_linux_cross_env
}

cross_effective_targets_raw() {
  cross_targets_effective_raw "$@"
}

cross_bin_dir() {
  printf '%s' "${CROSS_BIN_DIR:-/opt/cross-bin}"
}

cross_target_triplet_for_arch() {
  arch_deb_multiarch_triplet_for "$1"
}

cross_target_triplet() {
  cross_target_triplet_for_arch "$(cross_target_arch)"
}

cross_target_rust_triple() {
  rust_target_triple
}

cross_build_rust_triple() {
  case "$(cross_build_arch)" in
    amd64) printf '%s' "x86_64-unknown-linux-gnu" ;;
    arm64) printf '%s' "aarch64-unknown-linux-gnu" ;;
    386) printf '%s' "i686-unknown-linux-gnu" ;;
    riscv64) printf '%s' "riscv64gc-unknown-linux-gnu" ;;
    *) printf '%s' "" ;;
  esac
}

cross_target_cpu_family() {
  arch_cpu_family_for "$(cross_target_arch)"
}

cross_target_cpu() {
  arch_cpu_for "$(cross_target_arch)"
}

cross_target_upper_rust() {
  cross_target_rust_triple | tr '[:lower:]-' '[:upper:]_'
}

cross_build_upper_rust() {
  cross_build_rust_triple | tr '[:lower:]-' '[:upper:]_'
}

cross_target_lower_rust() {
  cross_target_rust_triple | tr '[:upper:]-' '[:lower:]_'
}

cross_build_lower_rust() {
  cross_build_rust_triple | tr '[:upper:]-' '[:lower:]_'
}

install_cross_bin_symlinks() {
  local target_arch="${1:-${TARGET_ARCH:-${TARGETARCH:-${ARCH:-}}}}"
  local bin_dir="${2:-$(cross_bin_dir)}"
  local triplet=""
  local cc=""
  local cxx=""
  local ar=""
  local as=""
  local ld=""
  local nm=""
  local ranlib=""
  local strip=""
  local objcopy=""

  target_arch="$(cross_require_single_target_arch "${target_arch}" "cross tool symlink setup")" || return 1
  triplet="$(cross_target_triplet_for_arch "${target_arch}")" || {
    printf 'Unsupported cross tool target: %s\n' "${target_arch}" >&2
    return 1
  }

  cc="$(resolve_cross_gcc_tool gcc "${triplet}")" || return 1
  cxx="$(resolve_cross_gcc_tool g++ "${triplet}")" || return 1
  ar="$(resolve_cross_gcc_tool ar "${triplet}")" || return 1
  as="$(resolve_cross_gcc_tool as "${triplet}")" || return 1
  ld="$(resolve_cross_gcc_tool ld "${triplet}")" || return 1
  nm="$(resolve_cross_gcc_tool nm "${triplet}")" || return 1
  ranlib="$(resolve_cross_gcc_tool ranlib "${triplet}")" || return 1
  strip="$(resolve_cross_gcc_tool strip "${triplet}")" || return 1
  objcopy="$(resolve_cross_gcc_tool objcopy "${triplet}")" || return 1

  mkdir -p "${bin_dir}"
  ln -sf "${cc}" "${bin_dir}/gcc"
  ln -sf "${cxx}" "${bin_dir}/g++"
  ln -sf "${cc}" "${bin_dir}/cc"
  ln -sf "${cxx}" "${bin_dir}/c++"
  ln -sf "${as}" "${bin_dir}/as"
  ln -sf "${ld}" "${bin_dir}/ld"
  ln -sf "${ar}" "${bin_dir}/ar"
  ln -sf "${nm}" "${bin_dir}/nm"
  ln -sf "${ranlib}" "${bin_dir}/ranlib"
  ln -sf "${strip}" "${bin_dir}/strip"
  ln -sf "${objcopy}" "${bin_dir}/objcopy"

  if command -v "clang-${target_arch}" >/dev/null 2>&1; then
    ln -sf "$(command -v "clang-${target_arch}")" "${bin_dir}/clang"
  fi
  if command -v "clang++-${target_arch}" >/dev/null 2>&1; then
    ln -sf "$(command -v "clang++-${target_arch}")" "${bin_dir}/clang++"
  fi
}

_cross_first_executable() {
  local candidate resolved

  for candidate in "$@"; do
    [ -n "${candidate}" ] || continue
    if [ -x "${candidate}" ]; then
      printf '%s' "${candidate}"
      return 0
    fi
    if resolved="$(command -v "${candidate}" 2>/dev/null || true)" && [ -n "${resolved}" ]; then
      printf '%s' "${resolved}"
      return 0
    fi
  done

  return 1
}

cross_target_qemu_runner_for_arch() {
  local target_arch="$1"
  local qemu_arch=""

  case "$(arch_normalize "${target_arch}")" in
    amd64) qemu_arch="x86_64" ;;
    arm64) qemu_arch="aarch64" ;;
    386) qemu_arch="i386" ;;
    riscv64) qemu_arch="riscv64" ;;
    *) return 1 ;;
  esac

  _cross_first_executable \
    "/usr/bin/qemu-${qemu_arch}-static" \
    "/usr/bin/qemu-${qemu_arch}" \
    "$(command -v "qemu-${qemu_arch}-static" 2>/dev/null || true)" \
    "$(command -v "qemu-${qemu_arch}" 2>/dev/null || true)"
}

cross_target_qemu_runner() {
  cross_target_qemu_runner_for_arch "$(cross_target_arch)"
}


# shellcheck disable=SC1091
source "${_CROSS_ENV_DIR}/cross-gcc.sh"
# shellcheck disable=SC1091
source "${_CROSS_ENV_DIR}/cross-python.sh"
# shellcheck disable=SC1091
source "${_CROSS_ENV_DIR}/cross-apt.sh"
# shellcheck disable=SC1091
source "${_CROSS_ENV_DIR}/cross-meson.sh"

# Private: resolve the core architecture identifiers (triplet, rust target, etc.).
# Populates the provided associative array with keys:
#   target_arch, build_arch, triplet, processor, rust_target, rust_env,
#   rust_env_lower, build_rust_lower, gcc_prefix, gcc_major, runtime_libdir
_cross_env_resolve_identifiers() {
  local -n _eri_out=$1

  _eri_out[target_arch]="$(cross_target_arch)"
  _eri_out[build_arch]="$(cross_build_arch)"
  _eri_out[triplet]="$(cross_target_triplet)"
  _eri_out[processor]="$(cmake_system_processor)"
  _eri_out[rust_target]="$(cross_target_rust_triple)"
  _eri_out[rust_env]="$(cross_target_upper_rust)"
  _eri_out[rust_env_lower]="$(cross_target_lower_rust)"
  _eri_out[build_rust_lower]="$(cross_build_lower_rust 2>/dev/null || true)"
  _eri_out[gcc_prefix]="/opt/gcc-${GCC_VERSION:-16.1.0}"
  _eri_out[gcc_major]="${GCC_WANTED:-${GCC_VERSION:-16}}"
  _eri_out[gcc_major]="$(version_major "${_eri_out[gcc_major]}")"
  _eri_out[runtime_libdir]="${_eri_out[gcc_prefix]}/lib/gcc/${_eri_out[triplet]}/${_eri_out[gcc_major]}"
}

# Private: resolve all cross-compiler tool paths for a target triplet.
# Populates the provided associative array with keys:
#   cc, cxx, ar, as, ld, nm, ranlib, strip, objcopy,
#   build_cc, build_cxx, build_ar, build_ranlib
_cross_env_resolve_tools() {
  local triplet="$1"
  local -n _ert_out=$2

  _ert_out[cc]="$(require_cross_gcc_tool gcc "${triplet}" 'cross compiler')" || return 1
  if ! _ert_out[cxx]="$(require_cross_gcc_tool g++ "${triplet}" 'cross compiler')"; then
    # Some cross-triplet g++ binaries may not be found by
    # resolve_cross_gcc_tool even though they exist. Derive from CC.
    if command -v derive_cxx_from_cc >/dev/null 2>&1; then
      _ert_out[cxx]="$(derive_cxx_from_cc "${_ert_out[cc]}")" || return 1
    else
      _cxx_fb="$(printf '%s' "${_ert_out[cc]}" | sed 's/-gcc$/-g++/')"
      [ -x "${_cxx_fb}" ] && _ert_out[cxx]="${_cxx_fb}" || return 1
    fi
  fi
  _ert_out[ar]="$(require_cross_gcc_tool ar "${triplet}" 'cross binutils tool')" || return 1
  _ert_out[as]="$(require_cross_gcc_tool as "${triplet}" 'cross binutils tool')" || return 1
  _ert_out[ld]="$(require_cross_gcc_tool ld "${triplet}" 'cross binutils tool')" || return 1
  _ert_out[nm]="$(require_cross_gcc_tool nm "${triplet}" 'cross binutils tool')" || return 1
  _ert_out[ranlib]="$(require_cross_gcc_tool ranlib "${triplet}" 'cross binutils tool')" || return 1
  _ert_out[strip]="$(require_cross_gcc_tool strip "${triplet}" 'cross binutils tool')" || return 1
  _ert_out[objcopy]="$(require_cross_gcc_tool objcopy "${triplet}" 'cross binutils tool')" || return 1
  _ert_out[build_cc]="$(resolve_build_gcc_tool gcc 2>/dev/null || true)"
  _ert_out[build_cxx]="$(resolve_build_gcc_tool g++ 2>/dev/null || true)"
  _ert_out[build_ar]="$(resolve_build_gcc_tool ar 2>/dev/null || true)"
  _ert_out[build_ranlib]="$(resolve_build_gcc_tool ranlib 2>/dev/null || true)"
}

# Private: set up cross Python staging directories.
_cross_env_setup_python_staging() {
  local target_arch="$1"

  export PYTHON_CROSS_STAGE_ROOT="${PYTHON_CROSS_STAGE_ROOT:-/opt/python-cross}"
  local _active="${PYTHON_CROSS_ACTIVE_ROOT:-}"
  if [ -z "${_active}" ] || [ ! -d "${_active}/usr/local" ]; then
    local _stage="${PYTHON_CROSS_STAGE_ROOT:-/opt/python-cross}/${target_arch}"
    if [ -d "${_stage}/usr/local" ]; then
      PYTHON_CROSS_ACTIVE_ROOT="${_stage}"
    else
      PYTHON_CROSS_ACTIVE_ROOT="${PYTHON_CROSS_ACTIVE_ROOT:-/opt/python-target}"
    fi
  fi
  export PYTHON_CROSS_ACTIVE_ROOT
}

# Private: export the full cross-compilation environment.
# Consumes a single associative array with all the keys produced by
# _cross_env_resolve_identifiers and _cross_env_resolve_tools.
_cross_env_export_all() {
  local -n _eea=$1

  export TARGET_ARCH="${_eea[target_arch]}"
  export TARGETARCH="${_eea[target_arch]}"
  export TARGETPLATFORM="linux/${_eea[target_arch]}"
  export BUILDARCH="${_eea[build_arch]}"
  export BUILDPLATFORM="linux/${_eea[build_arch]}"
  export CROSS_TARGET_TRIPLET="${_eea[triplet]}"
  export CROSS_TARGET_PROCESSOR="${_eea[processor]}"
  export CROSS_RUST_TARGET="${_eea[rust_target]}"

  local dir
  dir="$(cross_bin_dir 2>/dev/null || true)"
  if [ -n "${dir}" ] && [ -d "${dir}" ]; then
    export PATH="${dir}:${PATH}"
  fi

  export CC="${_eea[cc]}" CXX="${_eea[cxx]}" AR="${_eea[ar]}" AS="${_eea[as]}" \
    LD="${_eea[ld]}" NM="${_eea[nm]}" RANLIB="${_eea[ranlib]}" \
    STRIP="${_eea[strip]}" OBJCOPY="${_eea[objcopy]}"
  export "CC_${_eea[rust_env_lower]}=${CC}"
  export "CXX_${_eea[rust_env_lower]}=${CXX}"
  export "AR_${_eea[rust_env_lower]}=${AR}"
  export "RANLIB_${_eea[rust_env_lower]}=${RANLIB}"
  if [ -n "${_eea[build_rust_lower]}" ]; then
    [ -n "${_eea[build_cc]}" ] && export "CC_${_eea[build_rust_lower]}=${_eea[build_cc]}"
    [ -n "${_eea[build_cxx]}" ] && export "CXX_${_eea[build_rust_lower]}=${_eea[build_cxx]}"
    [ -n "${_eea[build_ar]}" ] && export "AR_${_eea[build_rust_lower]}=${_eea[build_ar]}"
    [ -n "${_eea[build_ranlib]}" ] && export "RANLIB_${_eea[build_rust_lower]}=${_eea[build_ranlib]}"
  fi

  if command -v "clang-${_eea[target_arch]}" >/dev/null 2>&1; then
    export CLANG="clang-${_eea[target_arch]}"
  fi
  if command -v "clang++-${_eea[target_arch]}" >/dev/null 2>&1; then
    export CLANGXX="clang++-${_eea[target_arch]}"
  fi

  export PKG_CONFIG_ALLOW_CROSS=1
  export PKG_CONFIG_SYSROOT_DIR="${PKG_CONFIG_SYSROOT_DIR:-/}"
  PKG_CONFIG_LIBDIR="$(cross_pkg_config_libdir "${_eea[triplet]}")"
  export PKG_CONFIG_LIBDIR

  local target_link_path=""
  for dir in \
    "${_eea[runtime_libdir]}" \
    "${_eea[gcc_prefix]}/${_eea[triplet]}/lib" \
    "/usr/lib/${_eea[triplet]}" \
    "/lib/${_eea[triplet]}" \
    "/usr/${_eea[triplet]}/lib"; do
    [ -d "${dir}" ] || continue
    target_link_path="${target_link_path:+${target_link_path}:}${dir}"
  done
  if [ -n "${target_link_path}" ]; then
    export LIBRARY_PATH="${target_link_path}${LIBRARY_PATH:+:${LIBRARY_PATH}}"
  fi

  export CMAKE_SYSTEM_NAME=Linux
  export CMAKE_SYSTEM_PROCESSOR="${_eea[processor]}"
  export CMAKE_SYSROOT="${CMAKE_SYSROOT:-/}"
  export CMAKE_C_COMPILER="${CC}"
  export CMAKE_CXX_COMPILER="${CXX}"
  export CMAKE_ASM_COMPILER="${CC}"
  export CMAKE_AR="${AR}"
  export CMAKE_RANLIB="${RANLIB}"
  export CMAKE_LINKER="${_eea[ld]:-}"
  export CMAKE_NM="${_eea[nm]:-}"
  export CMAKE_OBJCOPY="${_eea[objcopy]}"
  export CMAKE_STRIP="${_eea[strip]}"
  export CMAKE_LIBRARY_ARCHITECTURE="${_eea[triplet]}"
  export CMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
  export CMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
  export CMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
  export CMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
  export CARGO_BUILD_TARGET="${_eea[rust_target]}"
  export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/opt/cargo-target/${_eea[target_arch]}}"
  export "CARGO_TARGET_${_eea[rust_env]}_LINKER=${CC}"
  export "CARGO_TARGET_${_eea[rust_env]}_AR=${AR}"
  # The `cc` crate (build scripts of ring, openssl-sys, …) does NOT read
  # CARGO_TARGET_*_LINKER — it needs CC_<target>/CXX_<target>. Without it, it
  # guesses `<triple>-gcc`, which for riscv64gc-unknown-linux-gnu does not exist,
  # so it falls back to the host gcc and passes it the target -mabi=lp64d flag →
  # "unrecognized argument in option '-mabi=lp64d'". Point it at the cross-GCC.
  local _cross_rust_env_lc
  _cross_rust_env_lc="$(cross_target_rust_triple | tr '[:upper:]-' '[:lower:]_')"
  export "CC_${_cross_rust_env_lc}=${CC}"
  [ -n "${CXX:-}" ] && export "CXX_${_cross_rust_env_lc}=${CXX}"
  [ -n "${AR:-}" ] && export "AR_${_cross_rust_env_lc}=${AR}"
}

setup_linux_cross_env() {
  if ! cross_build_enabled; then
    return 0
  fi

  local -A _env=()

  _cross_env_resolve_identifiers _env
  _cross_env_setup_python_staging "${_env[target_arch]}"
  _cross_env_resolve_tools "${_env[triplet]}" _env || return 1
  _cross_env_export_all _env
}

