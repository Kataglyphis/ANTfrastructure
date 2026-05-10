#!/usr/bin/env bash
# cross-env.sh - shared helpers for amd64-hosted target builds

_CROSS_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CROSS_ENV_APT_UPDATED="${_CROSS_ENV_APT_UPDATED:-0}"

# shellcheck disable=SC1090,SC1091
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

cross_build_rust_triple() {
  case "$(cross_build_arch)" in
    amd64) printf '%s' "x86_64-unknown-linux-gnu" ;;
    arm64) printf '%s' "aarch64-unknown-linux-gnu" ;;
    386) printf '%s' "i686-unknown-linux-gnu" ;;
    riscv64) printf '%s' "riscv64gc-unknown-linux-gnu" ;;
    *) printf '%s' "" ;;
  esac
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

cross_build_upper_rust() {
  cross_build_rust_triple | tr '[:lower:]-' '[:upper:]_'
}

cross_target_lower_rust() {
  cross_target_rust_triple | tr '[:upper:]-' '[:lower:]_'
}

cross_build_lower_rust() {
  cross_build_rust_triple | tr '[:upper:]-' '[:lower:]_'
}

_cross_first_executable() {
  local candidate

  for candidate in "$@"; do
    [ -n "${candidate}" ] || continue
    [ -x "${candidate}" ] && {
      printf '%s' "${candidate}"
      return 0
    }
  done

  return 1
}

gcc_toolchain_prefix() {
  printf '%s' "/opt/gcc-${GCC_VERSION:-16.1.0}"
}

gcc_toolchain_bindir() {
  printf '%s' "$(gcc_toolchain_prefix)/bin"
}

resolve_build_gcc_tool() {
  local tool="$1"
  local bindir build_triplet resolved=""

  bindir="$(gcc_toolchain_bindir)"
  build_triplet="$(build_deb_multiarch_triplet 2>/dev/null || true)"

  case "${tool}" in
    gcc|g++|cpp|gcov|gcc-ar|gcc-nm|gcc-ranlib)
      resolved="$(_cross_first_executable \
        "${bindir}/${tool}" \
        "${build_triplet:+${bindir}/${build_triplet}-${tool}}" \
        "${build_triplet:+/usr/bin/${build_triplet}-${tool}}" \
        "/usr/bin/${tool}" || true)"
      ;;
    *)
      resolved="$(_cross_first_executable \
        "${build_triplet:+${bindir}/${build_triplet}-${tool}}" \
        "${build_triplet:+/usr/bin/${build_triplet}-${tool}}" \
        "/usr/bin/${tool}" || true)"
      ;;
  esac

  if [ -n "${resolved}" ]; then
    printf '%s' "${resolved}"
    return 0
  fi

  if [ -n "${build_triplet}" ] && command -v "${build_triplet}-${tool}" >/dev/null 2>&1; then
    command -v "${build_triplet}-${tool}"
    return 0
  fi

  command -v "${tool}" 2>/dev/null || return 1
}

resolve_cross_gcc_tool() {
  local tool="$1"
  local triplet="${2:-$(cross_target_triplet)}"
  local bindir candidate

  [ -n "${triplet}" ] || return 1

  bindir="$(gcc_toolchain_bindir)"
  candidate="${bindir}/${triplet}-${tool}"
  if [ -d "${bindir}" ]; then
    [ -x "${candidate}" ] || return 1
    printf '%s' "${candidate}"
    return 0
  fi

  if [ -x "/usr/bin/${triplet}-${tool}" ]; then
    printf '%s' "/usr/bin/${triplet}-${tool}"
    return 0
  fi

  command -v "${triplet}-${tool}" 2>/dev/null || return 1
}

make_host_compiler_wrapper() {
  local wrapper_path="$1"
  local compiler="$2"
  local host_path="${3:-/usr/bin:/bin}"

  [ -n "${wrapper_path}" ] || return 1
  [ -n "${compiler}" ] || return 1

  mkdir -p "$(dirname "${wrapper_path}")"
  cat > "${wrapper_path}" <<EOF
#!/usr/bin/env bash
exec env PATH="${host_path}" "${compiler}" -B/usr/bin/ "\$@"
EOF
  chmod +x "${wrapper_path}"
  printf '%s' "${wrapper_path}"
}

make_named_host_compiler_wrapper() {
  local wrapper_dir="$1"
  local wrapper_name="$2"
  local compiler="$3"

  [ -n "${wrapper_dir}" ] || return 1
  [ -n "${wrapper_name}" ] || return 1

  make_host_compiler_wrapper "${wrapper_dir}/${wrapper_name}" "${compiler}"
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

cross_target_python_major_minor() {
  if [ -n "${TARGET_PYTHON_MAJOR_MINOR:-}" ]; then
    printf '%s' "${TARGET_PYTHON_MAJOR_MINOR}"
    return 0
  fi

  if [ -n "${PYTHON_MAJOR_MINOR:-}" ]; then
    printf '%s' "${PYTHON_MAJOR_MINOR}"
    return 0
  fi

  host_python_major_minor
}

cross_target_python_include_dir() {
  local python_mm

  python_mm="$(cross_target_python_major_minor)" || return 1
  printf '%s' "/usr/include/python${python_mm}"
}

cross_target_python_arch_include_dir() {
  local python_mm
  local triplet

  python_mm="$(cross_target_python_major_minor)" || return 1
  if cross_build_enabled; then
    triplet="$(cross_target_triplet)"
    printf '%s' "/usr/include/${triplet}/python${python_mm}"
  else
    printf '%s' "/usr/include/python${python_mm}"
  fi
}

cross_target_python_libdir() {
  local triplet

  if cross_build_enabled; then
    triplet="$(cross_target_triplet)"
    printf '%s' "/usr/lib/${triplet}"
  else
    printf '%s' "/usr/lib"
  fi
}

cross_target_python_library() {
  local python_mm
  local triplet
  local candidate

  python_mm="$(cross_target_python_major_minor)" || return 1
  triplet="$(cross_target_triplet 2>/dev/null || true)"

  for candidate in \
    "/usr/lib/${triplet}/libpython${python_mm}.so" \
    "/usr/lib/${triplet}/libpython${python_mm}.so.1.0" \
    "/usr/lib/libpython${python_mm}.so" \
    "/usr/lib/libpython${python_mm}.so.1.0"; do
    [ -f "${candidate}" ] && {
      printf '%s' "${candidate}"
      return 0
    }
  done

  return 1
}

cross_target_python_pkgconfig_dir() {
  local triplet

  if cross_build_enabled; then
    triplet="$(cross_target_triplet)"
    printf '%s' "/usr/lib/${triplet}/pkgconfig"
  else
    printf '%s' "/usr/lib/pkgconfig"
  fi
}

cross_target_python_pc() {
  local python_mm
  local pkgconfig_dir

  python_mm="$(cross_target_python_major_minor)" || return 1
  pkgconfig_dir="$(cross_target_python_pkgconfig_dir)" || return 1
  printf '%s' "${pkgconfig_dir}/python-${python_mm}.pc"
}

cross_target_python_embed_pc() {
  local python_mm
  local pkgconfig_dir

  python_mm="$(cross_target_python_major_minor)" || return 1
  pkgconfig_dir="$(cross_target_python_pkgconfig_dir)" || return 1
  printf '%s' "${pkgconfig_dir}/python-${python_mm}-embed.pc"
}

cross_target_python_dev_ready() {
  local include_dir
  local arch_include_dir
  local pc_file
  local embed_pc_file

  include_dir="$(cross_target_python_include_dir)" || return 1
  arch_include_dir="$(cross_target_python_arch_include_dir)" || return 1
  pc_file="$(cross_target_python_pc)" || return 1
  embed_pc_file="$(cross_target_python_embed_pc)" || return 1

  [ -d "${include_dir}" ] || return 1
  [ -d "${arch_include_dir}" ] || return 1
  [ -f "${pc_file}" ] || return 1
  [ -f "${embed_pc_file}" ] || return 1
  cross_target_python_library >/dev/null
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
  local triplet target_arch processor rust_target rust_env rust_env_lower build_arch
  local build_rust_lower gcc_prefix gcc_major runtime_libdir
  local cc cxx ar as ld nm ranlib strip objcopy
  local build_cc build_cxx build_ar build_ranlib

  if ! cross_build_enabled; then
    return 0
  fi

  target_arch="$(cross_target_arch)"
  build_arch="$(cross_build_arch)"
  triplet="$(cross_target_triplet)"
  processor="$(cmake_system_processor)"
  rust_target="$(cross_target_rust_triple)"
  rust_env="$(cross_target_upper_rust)"
  rust_env_lower="$(cross_target_lower_rust)"
  build_rust_lower="$(cross_build_lower_rust 2>/dev/null || true)"
  gcc_prefix="/opt/gcc-${GCC_VERSION:-16.1.0}"
  gcc_major="${GCC_WANTED:-16}"
  gcc_major="${gcc_major%%.*}"
  runtime_libdir="${gcc_prefix}/lib/gcc/${triplet}/${gcc_major}"
  cc="$(resolve_cross_gcc_tool gcc "${triplet}")" || {
    printf 'Missing cross compiler: %s\n' "${gcc_prefix}/bin/${triplet}-gcc" >&2
    return 1
  }
  cxx="$(resolve_cross_gcc_tool g++ "${triplet}")" || {
    printf 'Missing cross compiler: %s\n' "${gcc_prefix}/bin/${triplet}-g++" >&2
    return 1
  }
  ar="$(resolve_cross_gcc_tool ar "${triplet}")" || {
    printf 'Missing cross binutils tool: %s\n' "${gcc_prefix}/bin/${triplet}-ar" >&2
    return 1
  }
  as="$(resolve_cross_gcc_tool as "${triplet}")" || {
    printf 'Missing cross binutils tool: %s\n' "${gcc_prefix}/bin/${triplet}-as" >&2
    return 1
  }
  ld="$(resolve_cross_gcc_tool ld "${triplet}")" || {
    printf 'Missing cross binutils tool: %s\n' "${gcc_prefix}/bin/${triplet}-ld" >&2
    return 1
  }
  nm="$(resolve_cross_gcc_tool nm "${triplet}")" || {
    printf 'Missing cross binutils tool: %s\n' "${gcc_prefix}/bin/${triplet}-nm" >&2
    return 1
  }
  ranlib="$(resolve_cross_gcc_tool ranlib "${triplet}")" || {
    printf 'Missing cross binutils tool: %s\n' "${gcc_prefix}/bin/${triplet}-ranlib" >&2
    return 1
  }
  strip="$(resolve_cross_gcc_tool strip "${triplet}")" || {
    printf 'Missing cross binutils tool: %s\n' "${gcc_prefix}/bin/${triplet}-strip" >&2
    return 1
  }
  objcopy="$(resolve_cross_gcc_tool objcopy "${triplet}")" || {
    printf 'Missing cross binutils tool: %s\n' "${gcc_prefix}/bin/${triplet}-objcopy" >&2
    return 1
  }
  build_cc="$(resolve_build_gcc_tool gcc 2>/dev/null || true)"
  build_cxx="$(resolve_build_gcc_tool g++ 2>/dev/null || true)"
  build_ar="$(resolve_build_gcc_tool ar 2>/dev/null || true)"
  build_ranlib="$(resolve_build_gcc_tool ranlib 2>/dev/null || true)"

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

  export CC="${cc}" CXX="${cxx}" AR="${ar}" AS="${as}" LD="${ld}" NM="${nm}" \
    RANLIB="${ranlib}" STRIP="${strip}" OBJCOPY="${objcopy}"
  export "CC_${rust_env_lower}=${CC}"
  export "CXX_${rust_env_lower}=${CXX}"
  export "AR_${rust_env_lower}=${AR}"
  export "RANLIB_${rust_env_lower}=${RANLIB}"
  if [ -n "${build_rust_lower}" ]; then
    [ -n "${build_cc}" ] && export "CC_${build_rust_lower}=${build_cc}"
    [ -n "${build_cxx}" ] && export "CXX_${build_rust_lower}=${build_cxx}"
    [ -n "${build_ar}" ] && export "AR_${build_rust_lower}=${build_ar}"
    [ -n "${build_ranlib}" ] && export "RANLIB_${build_rust_lower}=${build_ranlib}"
  fi

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
  PKG_CONFIG_LIBDIR="$(cross_pkg_config_libdir "${triplet}")"
  export PKG_CONFIG_LIBDIR
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
  if command -v resolve_build_gcc_tool >/dev/null 2>&1; then
    native_cc="$(resolve_build_gcc_tool gcc 2>/dev/null || resolve_build_gcc_tool cc 2>/dev/null || true)"
    native_cxx="$(resolve_build_gcc_tool g++ 2>/dev/null || resolve_build_gcc_tool c++ 2>/dev/null || true)"
    native_ar="$(resolve_build_gcc_tool ar 2>/dev/null || true)"
    native_strip="$(resolve_build_gcc_tool strip 2>/dev/null || true)"
  else
    native_cc="$(PATH="${host_path}" command -v gcc || PATH="${host_path}" command -v cc || true)"
    native_cxx="$(PATH="${host_path}" command -v g++ || PATH="${host_path}" command -v c++ || true)"
    native_ar="$(PATH="${host_path}" command -v ar || true)"
    native_strip="$(PATH="${host_path}" command -v strip || true)"
  fi
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
  local out_name="$1"
  local -n meson_cross_flags_ref="${out_name}"

  cross_build_enabled || return 0
  ensure_meson_cross_file
  meson_cross_flags_ref+=(--cross-file "${MESON_CROSS_FILE}")
}

append_meson_native_flags() {
  local out_name="$1"
  local -n meson_native_flags_ref="${out_name}"

  cross_build_enabled || return 0
  ensure_meson_native_file
  meson_native_flags_ref+=(--native-file "${MESON_NATIVE_FILE}")
}
