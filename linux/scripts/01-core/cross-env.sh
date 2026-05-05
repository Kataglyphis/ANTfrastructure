#!/usr/bin/env bash
# cross-env.sh - shared helpers for amd64-hosted target builds

_CROSS_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CROSS_ENV_APT_UPDATED="${_CROSS_ENV_APT_UPDATED:-0}"

# shellcheck disable=SC1090
[ -f "${_CROSS_ENV_DIR}/platform.sh" ] && source "${_CROSS_ENV_DIR}/platform.sh"

cross_build_enabled() {
  [ "${BUILD_MODE:-native}" = "cross" ] || return 1
  [ "$(build_arch_oci)" != "$(arch_oci)" ]
}

cross_target_arch() {
  arch_oci
}

cross_build_arch() {
  build_arch_oci
}

cross_target_triplet() {
  deb_multiarch_triplet
}

cross_target_rust_triple() {
  rust_target_triple
}

cross_target_android_abi() {
  android_abi_for_target
}

cross_target_cpu_family() {
  case "$(cross_target_arch)" in
    amd64) printf '%s' "x86_64" ;;
    arm64) printf '%s' "aarch64" ;;
    386) printf '%s' "x86" ;;
    riscv64) printf '%s' "riscv64" ;;
    *) printf '%s' "$(cross_target_arch)" ;;
  esac
}

cross_target_cpu() {
  case "$(cross_target_arch)" in
    386) printf '%s' "i686" ;;
    *) cross_target_cpu_family ;;
  esac
}

cross_target_upper_rust() {
  cross_target_rust_triple | tr '[:lower:]-' '[:upper:]_'
}

cross_prepare_foreign_arch() {
  local target_arch
  cross_build_enabled || return 0
  target_arch="$(cross_target_arch)"
  if ! dpkg --print-foreign-architectures | grep -qx "${target_arch}"; then
    dpkg --add-architecture "${target_arch}"
    _CROSS_ENV_APT_UPDATED=0
  fi
}

cross_resolve_target_package() {
  local pkg="$1"
  local target_arch
  target_arch="$(cross_target_arch)"

  if ! cross_build_enabled; then
    printf '%s' "${pkg}"
    return 0
  fi

  if apt-cache show "${pkg}:${target_arch}" >/dev/null 2>&1; then
    printf '%s' "${pkg}:${target_arch}"
  else
    printf '%s' "${pkg}"
  fi
}

install_host_packages() {
  [ "$#" -gt 0 ] || return 0
  apt-get install -y --no-install-recommends "$@"
}

install_target_packages() {
  local pkg resolved
  local -a pkgs=()

  [ "$#" -gt 0 ] || return 0
  if cross_build_enabled; then
    cross_prepare_foreign_arch
    if [ "${_CROSS_ENV_APT_UPDATED}" != "1" ]; then
      apt-get update
      _CROSS_ENV_APT_UPDATED=1
    fi
  fi

  for pkg in "$@"; do
    resolved="$(cross_resolve_target_package "${pkg}")"
    [ -n "${resolved}" ] && pkgs+=("${resolved}")
  done

  [ "${#pkgs[@]}" -gt 0 ] || return 0
  apt-get install -y --no-install-recommends "${pkgs[@]}"
}

setup_linux_cross_env() {
  local triplet target_arch processor rust_target rust_env build_arch
  local gcc_prefix gcc_major runtime_libdir

  if ! cross_build_enabled; then
    return 0
  fi

  target_arch="$(cross_target_arch)"
  build_arch="$(cross_build_arch)"
  triplet="$(cross_target_triplet)"
  processor="$(cmake_system_processor)"
  rust_target="$(cross_target_rust_triple)"
  rust_env="$(cross_target_upper_rust)"
  gcc_prefix="/opt/gcc-${GCC_VERSION:-16.1.0}"
  gcc_major="${GCC_WANTED:-16}"
  gcc_major="${gcc_major%%.*}"
  runtime_libdir="${gcc_prefix}/lib/gcc/${triplet}/${gcc_major}"

  export TARGET_ARCH="${target_arch}"
  export TARGETARCH="${target_arch}"
  export TARGETPLATFORM="linux/${target_arch}"
  export BUILDARCH="${build_arch}"
  export BUILDPLATFORM="linux/${build_arch}"
  export CROSS_TARGET_TRIPLET="${triplet}"
  export CROSS_TARGET_PROCESSOR="${processor}"
  export CROSS_RUST_TARGET="${rust_target}"

  if [ -d /opt/cross-bin ]; then
    export PATH="/opt/cross-bin:${PATH}"
  fi

  case "${target_arch}" in
    amd64)
      export CC=gcc CXX=g++ AR=ar RANLIB=ranlib STRIP=strip OBJCOPY=objcopy
      ;;
    *)
      export CC="${triplet}-gcc" CXX="${triplet}-g++" AR="${triplet}-ar" \
        AS="${triplet}-as" LD="${triplet}-ld" NM="${triplet}-nm" \
        RANLIB="${triplet}-ranlib" STRIP="${triplet}-strip" OBJCOPY="${triplet}-objcopy"
      ;;
  esac

  if command -v "clang-${target_arch}" >/dev/null 2>&1; then
    export CLANG="clang-${target_arch}"
  fi
  if command -v "clang++-${target_arch}" >/dev/null 2>&1; then
    export CLANGXX="clang++-${target_arch}"
  fi

  export PKG_CONFIG_ALLOW_CROSS=1
  export PKG_CONFIG_SYSROOT_DIR="${PKG_CONFIG_SYSROOT_DIR:-/}"
  export PKG_CONFIG_LIBDIR="/usr/${triplet}/lib/pkgconfig:/usr/lib/${triplet}/pkgconfig:/usr/lib/pkgconfig:/usr/local/lib/pkgconfig:/usr/share/pkgconfig${PKG_CONFIG_LIBDIR:+:${PKG_CONFIG_LIBDIR}}"
  if [ -d "${runtime_libdir}" ]; then
    export LIBRARY_PATH="${runtime_libdir}:${gcc_prefix}/${triplet}/lib${LIBRARY_PATH:+:${LIBRARY_PATH}}"
    export LD_LIBRARY_PATH="${runtime_libdir}:${gcc_prefix}/${triplet}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
  fi
  export CMAKE_SYSTEM_NAME=Linux
  export CMAKE_SYSTEM_PROCESSOR="${processor}"
  export CMAKE_SYSROOT="${CMAKE_SYSROOT:-/}"
  export CMAKE_C_COMPILER="${CC}"
  export CMAKE_CXX_COMPILER="${CXX}"
  export CMAKE_ASM_COMPILER="${CC}"
  export CMAKE_AR="${AR}"
  export CMAKE_RANLIB="${RANLIB}"
  export CMAKE_LINKER="${LD:-}"
  export CMAKE_NM="${NM:-}"
  export CMAKE_OBJCOPY="${OBJCOPY}"
  export CMAKE_STRIP="${STRIP}"
  export CMAKE_LIBRARY_ARCHITECTURE="${triplet}"
  export CMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
  export CMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
  export CMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
  export CMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
  export CARGO_BUILD_TARGET="${rust_target}"
  export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/opt/cargo-target/${target_arch}}"
  export "CARGO_TARGET_${rust_env}_LINKER=${CC}"
  export "CARGO_TARGET_${rust_env}_AR=${AR}"
}

append_cmake_cross_args() {
  local -n _out="$1"

  cross_build_enabled || return 0
  setup_linux_cross_env

  _out+=(
    "-DCMAKE_SYSTEM_NAME=Linux"
    "-DCMAKE_SYSTEM_PROCESSOR=${CROSS_TARGET_PROCESSOR}"
    "-DCMAKE_SYSROOT=${CMAKE_SYSROOT:-/}"
    "-DCMAKE_C_COMPILER=${CC}"
    "-DCMAKE_CXX_COMPILER=${CXX}"
    "-DCMAKE_ASM_COMPILER=${CC}"
    "-DCMAKE_AR=${AR}"
    "-DCMAKE_RANLIB=${RANLIB}"
    "-DCMAKE_LIBRARY_ARCHITECTURE=${CROSS_TARGET_TRIPLET}"
    "-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER"
    "-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY"
    "-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY"
    "-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY"
    "-DPKG_CONFIG_USE_CMAKE_PREFIX_PATH=ON"
  )
}

ensure_meson_cross_file() {
  local path="${1:-/tmp/meson-cross-$(cross_target_arch).ini}"

  cross_build_enabled || return 0
  setup_linux_cross_env

  cat > "${path}" <<EOF
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR}'
strip = '${STRIP}'
pkg-config = 'pkg-config'
cmake = 'cmake'

[properties]
needs_exe_wrapper = true
sys_root = '/'
pkg_config_libdir = '${PKG_CONFIG_LIBDIR}'

[host_machine]
system = 'linux'
cpu_family = '$(cross_target_cpu_family)'
cpu = '$(cross_target_cpu)'
endian = 'little'
EOF

  export MESON_CROSS_FILE="${path}"
}

append_meson_cross_flags() {
  local -n _out="$1"

  cross_build_enabled || return 0
  ensure_meson_cross_file
  _out+=(--cross-file "${MESON_CROSS_FILE}")
}
