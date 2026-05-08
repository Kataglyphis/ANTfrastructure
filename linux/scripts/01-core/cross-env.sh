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

host_python_bin() {
  if [ -n "${MEDIA_HOST_PYTHON:-}" ] && [ -x "${MEDIA_HOST_PYTHON}" ]; then
    printf '%s' "${MEDIA_HOST_PYTHON}"
    return 0
  fi

  if [ -n "${UV_PYTHON:-}" ] && [ -x "${UV_PYTHON}" ]; then
    printf '%s' "${UV_PYTHON}"
    return 0
  fi

  if [ -n "${VIRTUAL_ENV:-}" ] && [ -x "${VIRTUAL_ENV}/bin/python" ]; then
    printf '%s' "${VIRTUAL_ENV}/bin/python"
    return 0
  fi

  if [ -n "${PYTHON_MAJOR_MINOR:-}" ] && [ -x "/usr/local/bin/python${PYTHON_MAJOR_MINOR}" ]; then
    printf '%s' "/usr/local/bin/python${PYTHON_MAJOR_MINOR}"
    return 0
  fi

  if [ -x /usr/local/bin/python3.14 ]; then
    printf '%s' "/usr/local/bin/python3.14"
    return 0
  fi

  command -v python3 2>/dev/null || command -v python 2>/dev/null || return 1
}

host_python_major_minor() {
  local python_bin

  if [ -n "${PYTHON_MAJOR_MINOR:-}" ]; then
    printf '%s' "${PYTHON_MAJOR_MINOR}"
    return 0
  fi

  python_bin="$(host_python_bin)" || return 1
  "${python_bin}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")'
}

cross_target_uses_ubuntu_ports() {
  case "$(cross_target_arch)" in
    arm64|armhf|ppc64el|riscv64|s390x) return 0 ;;
    *) return 1 ;;
  esac
}

cross_configure_foreign_arch_apt_sources() {
  local target_arch build_arch distro ports_url host_sources ports_sources tmp

  cross_build_enabled || return 0
  cross_target_uses_ubuntu_ports || return 0

  target_arch="$(cross_target_arch)"
  build_arch="$(cross_build_arch)"
  distro="${DISTRO:-${UBUNTU_CODENAME:-${VERSION_CODENAME:-noble}}}"
  ports_url="${UBUNTU_PORTS_MIRROR_URL:-http://ports.ubuntu.com/ubuntu-ports/}"
  host_sources="/etc/apt/sources.list.d/ubuntu.sources"
  ports_sources="/etc/apt/sources.list.d/ubuntu-ports-${target_arch}.sources"

  case "${ports_url}" in
    */) ;;
    *) ports_url="${ports_url}/" ;;
  esac

  if [ -f "${host_sources}" ]; then
    tmp="$(mktemp)"
    awk -v arch="${build_arch}" '
      BEGIN { in_stanza=0; has_arch=0 }
      /^[[:space:]]*$/ {
        if (in_stanza && !has_arch) print "Architectures: " arch
        print
        in_stanza=0
        has_arch=0
        next
      }
      /^[[:space:]]*#/ {
        print
        next
      }
      {
        in_stanza=1
      }
      /^Architectures:[[:space:]]*/ {
        print "Architectures: " arch
        has_arch=1
        next
      }
      {
        print
      }
      END {
        if (in_stanza && !has_arch) print "Architectures: " arch
      }
    ' "${host_sources}" > "${tmp}"
    mv "${tmp}" "${host_sources}"
  fi

  printf 'Types: deb\nURIs: %s\nSuites: %s %s-updates %s-backports %s-security\nComponents: main universe restricted multiverse\nArchitectures: %s\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n' \
    "${ports_url}" "${distro}" "${distro}" "${distro}" "${distro}" "${target_arch}" > "${ports_sources}"
}

cross_prepare_foreign_arch() {
  local target_arch
  cross_build_enabled || return 0
  target_arch="$(cross_target_arch)"
  if ! dpkg --print-foreign-architectures | grep -qx "${target_arch}"; then
    dpkg --add-architecture "${target_arch}"
    _CROSS_ENV_APT_UPDATED=0
  fi
  cross_configure_foreign_arch_apt_sources
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

cross_pkg_config_libdir() {
  local triplet="${1:-$(cross_target_triplet)}"
  local dir path=""
  local old_ifs
  local -a candidates extra_dirs

  candidates=(
    "/usr/${triplet}/lib/pkgconfig"
    "/usr/lib/${triplet}/pkgconfig"
    "/usr/lib/pkgconfig"
    "/usr/local/lib/pkgconfig"
    "/usr/share/pkgconfig"
  )

  if [ -n "${PKG_CONFIG_PATH:-}" ]; then
    old_ifs="${IFS}"
    IFS=':' read -r -a extra_dirs <<< "${PKG_CONFIG_PATH}"
    IFS="${old_ifs}"
    candidates+=("${extra_dirs[@]}")
  fi

  for dir in "${candidates[@]}"; do
    [ -n "${dir}" ] || continue
    case ":${path}:" in
      *":${dir}:"*) continue ;;
    esac
    path="${path:+${path}:}${dir}"
  done

  printf '%s' "${path}"
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
  # Keep cross pkg-config lookups on target/system and explicit prefix paths.
  # Re-appending an inherited PKG_CONFIG_LIBDIR can leak build-machine pkg-config
  # directories back into cross builds.
  export PKG_CONFIG_LIBDIR="$(cross_pkg_config_libdir "${triplet}")"
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
  local triplet pkg_config_libdir exe_wrapper exe_wrapper_line wrapper_candidate

  cross_build_enabled || return 0
  setup_linux_cross_env

  triplet="$(cross_target_triplet)"
  pkg_config_libdir="$(cross_pkg_config_libdir "${triplet}")"
  exe_wrapper=""
  # Some cross builds need to run target-side helpers during Meson setup. Reuse
  # an explicitly provided wrapper first, then fall back to the target runner
  # pre-setup installs for cross GObject Introspection.
  if [ -n "${MESON_EXE_WRAPPER:-}" ] && [ -x "${MESON_EXE_WRAPPER}" ]; then
    exe_wrapper="${MESON_EXE_WRAPPER}"
  else
    wrapper_candidate="/usr/local/bin/g-ir-scanner-$(cross_target_arch)-binary-wrapper"
    if [ -x "${wrapper_candidate}" ]; then
      exe_wrapper="${wrapper_candidate}"
    fi
  fi
  exe_wrapper_line=""
  if [ -n "${exe_wrapper}" ]; then
    exe_wrapper_line="exe_wrapper = '${exe_wrapper}'"
  fi

  cat > "${path}" <<EOF
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR}'
strip = '${STRIP}'
pkg-config = 'pkg-config'
cmake = 'cmake'
${exe_wrapper_line}

[properties]
needs_exe_wrapper = true
sys_root = '/'
pkg_config_libdir = '${pkg_config_libdir}'

[host_machine]
system = 'linux'
cpu_family = '$(cross_target_cpu_family)'
cpu = '$(cross_target_cpu)'
endian = 'little'
EOF

  export MESON_CROSS_FILE="${path}"
}

ensure_meson_native_file() {
  local path="${1:-/tmp/meson-native-$(cross_build_arch).ini}"
  local host_path build_triplet native_cc native_cxx native_ar native_strip native_pkg_config native_cmake native_pkg_config_libdir
  local native_wrapper_dir native_cc_wrapper native_cxx_wrapper

  cross_build_enabled || return 0

  host_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  build_triplet="$(build_deb_multiarch_triplet)"
  native_cc="$(PATH="${host_path}" command -v gcc || PATH="${host_path}" command -v cc || true)"
  native_cxx="$(PATH="${host_path}" command -v g++ || PATH="${host_path}" command -v c++ || true)"
  native_ar="$(PATH="${host_path}" command -v ar || true)"
  native_strip="$(PATH="${host_path}" command -v strip || true)"
  native_pkg_config="$(PATH="${host_path}" command -v pkg-config || true)"
  native_cmake="$(PATH="${host_path}" command -v cmake || true)"
  if [ -n "${build_triplet}" ]; then
    native_pkg_config_libdir="/usr/lib/${build_triplet}/pkgconfig:/usr/lib/pkgconfig:/usr/local/lib/pkgconfig:/usr/share/pkgconfig"
  else
    native_pkg_config_libdir="/usr/lib/pkgconfig:/usr/local/lib/pkgconfig:/usr/share/pkgconfig"
  fi

  native_wrapper_dir="${MESON_NATIVE_TOOLCHAIN_DIR:-/tmp/meson-native-toolchain}"
  mkdir -p "${native_wrapper_dir}"

  if [ -n "${native_cc}" ]; then
    native_cc_wrapper="${native_wrapper_dir}/native-cc"
    cat > "${native_cc_wrapper}" <<EOF
#!/usr/bin/env bash
exec env PATH="${host_path}" "${native_cc}" -B/usr/bin/ "\$@"
EOF
    chmod +x "${native_cc_wrapper}"
    native_cc="${native_cc_wrapper}"
  fi

  if [ -n "${native_cxx}" ]; then
    native_cxx_wrapper="${native_wrapper_dir}/native-cxx"
    cat > "${native_cxx_wrapper}" <<EOF
#!/usr/bin/env bash
exec env PATH="${host_path}" "${native_cxx}" -B/usr/bin/ "\$@"
EOF
    chmod +x "${native_cxx_wrapper}"
    native_cxx="${native_cxx_wrapper}"
  fi

  cat > "${path}" <<EOF
[binaries]
c = '${native_cc}'
cpp = '${native_cxx}'
ar = '${native_ar}'
strip = '${native_strip}'
pkg-config = '${native_pkg_config}'
cmake = '${native_cmake}'

[properties]
pkg_config_libdir = '${native_pkg_config_libdir}'
EOF

  export MESON_NATIVE_FILE="${path}"
}

append_meson_cross_flags() {
  local -n _out="$1"

  cross_build_enabled || return 0
  ensure_meson_cross_file
  _out+=(--cross-file "${MESON_CROSS_FILE}")
}

append_meson_native_flags() {
  local -n _out="$1"

  cross_build_enabled || return 0
  ensure_meson_native_file
  _out+=(--native-file "${MESON_NATIVE_FILE}")
}
