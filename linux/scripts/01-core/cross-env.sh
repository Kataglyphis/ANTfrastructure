#!/usr/bin/env bash
# cross-env.sh - shared helpers for amd64-hosted target builds

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

cross_target_arch() {
  arch_oci
}

cross_build_arch() {
  build_arch_oci
}

cross_normalize_arch() {
  local raw="$1"

  [ -n "${raw}" ] || return 1
  arch_normalize "${raw}"
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

  target_arch="$(cross_normalize_arch "${raw}" 2>/dev/null || true)"
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
  cross_targets_effective_raw
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

cross_target_android_abi() {
  android_abi_for_target
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

cross_target_qemu_runner_for_arch() {
  local target_arch="$1"
  local qemu_arch=""

  case "$(cross_normalize_arch "${target_arch}")" in
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

require_cross_gcc_tool() {
  local tool="$1"
  local triplet="${2:-$(cross_target_triplet)}"
  local kind="${3:-cross tool}"
  local resolved=""

  resolved="$(resolve_cross_gcc_tool "${tool}" "${triplet}")" || {
    printf 'Missing %s: %s/bin/%s-%s\n' "${kind}" "$(gcc_toolchain_prefix)" "${triplet}" "${tool}" >&2
    return 1
  }

  printf '%s' "${resolved}"
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

make_meson_cross_rust_wrapper() {
  local wrapper_path="$1"
  local rustc_bin="$2"
  local rust_target="$3"

  [ -n "${wrapper_path}" ] || return 1
  [ -n "${rustc_bin}" ] || return 1
  [ -n "${rust_target}" ] || return 1

  mkdir -p "$(dirname "${wrapper_path}")"
  cat > "${wrapper_path}" <<EOF
#!/usr/bin/env bash
set -eu

want_target='${rust_target}'
have_target=false
expect_target_value=false
cargo_managed=false

for arg in "\$@"; do
  if [ "\${expect_target_value}" = "true" ]; then
    have_target=true
    expect_target_value=false
    continue
  fi

  case "\${arg}" in
    --target)
      expect_target_value=true
      ;;
    --target=*)
      have_target=true
      ;;
    */target/*)
      cargo_managed=true
      ;;
  esac
done

if [ "\${have_target}" = "true" ]; then
  exec '${rustc_bin}' "\$@"
fi

if [ "\${cargo_managed}" = "true" ]; then
  exec '${rustc_bin}' "\$@"
fi

exec '${rustc_bin}' --target "\${want_target}" "\$@"
EOF
  chmod +x "${wrapper_path}"
  printf '%s' "${wrapper_path}"
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

  if [ -n "${PYTHON_VERSION:-}" ] && command -v version_major_minor >/dev/null 2>&1; then
    local python_mm=""
    python_mm="$(version_major_minor "${PYTHON_VERSION}" 2>/dev/null || true)"
    if [ -n "${python_mm}" ] && [ -x "/usr/local/bin/python${python_mm}" ]; then
      printf '%s' "/usr/local/bin/python${python_mm}"
      return 0
    fi
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

cross_target_python_stage_root() {
  local target_arch=""

  target_arch="$(cross_require_single_target_arch "${1:-${TARGET_ARCH:-${TARGETARCH:-${ARCH:-}}}}" "target Python staging")" || return 1
  printf '%s' "${PYTHON_CROSS_STAGE_ROOT:-/opt/python-cross}/${target_arch}"
}

cross_target_python_active_stage_root() {
  local requested_arch="${1:-${TARGET_ARCH:-${TARGETARCH:-${ARCH:-}}}}"
  local active_root="${PYTHON_CROSS_ACTIVE_ROOT:-/opt/python-target}"
  local stage_root=""

  if [ -d "${active_root}/usr/local" ]; then
    printf '%s' "${active_root}"
    return 0
  fi

  stage_root="$(cross_target_python_stage_root "${requested_arch}" 2>/dev/null || true)"
  if [ -n "${stage_root}" ] && [ -d "${stage_root}/usr/local" ]; then
    printf '%s' "${stage_root}"
    return 0
  fi

  return 1
}

cross_target_python_root() {
  local active_root=""

  active_root="$(cross_target_python_active_stage_root "$@" 2>/dev/null || true)"
  if [ -n "${active_root}" ] && [ -d "${active_root}/usr/local" ]; then
    printf '%s' "${active_root}/usr/local"
    return 0
  fi

  return 1
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
  local python_root=""
  local candidate

  python_mm="$(cross_target_python_major_minor)" || return 1
  python_root="$(cross_target_python_root "$@" 2>/dev/null || true)"

  for candidate in \
    "${python_root:+${python_root}/include/python${python_mm}}" \
    "/usr/local/include/python${python_mm}" \
    "/usr/include/python${python_mm}"; do
    [ -n "${candidate}" ] || continue
    [ -d "${candidate}" ] && {
      printf '%s' "${candidate}"
      return 0
    }
  done

  return 1
}

cross_target_python_arch_include_dir() {
  local python_mm
  local triplet
  local python_root=""
  local candidate

  python_mm="$(cross_target_python_major_minor)" || return 1
  triplet="$(cross_target_triplet 2>/dev/null || true)"
  python_root="$(cross_target_python_root "$@" 2>/dev/null || true)"

  for candidate in \
    "${python_root:+${python_root}/include/${triplet}/python${python_mm}}" \
    "${python_root:+${python_root}/include/python${python_mm}}" \
    "/usr/local/include/${triplet}/python${python_mm}" \
    "/usr/include/${triplet}/python${python_mm}" \
    "/usr/local/include/python${python_mm}" \
    "/usr/include/python${python_mm}"; do
    [ -n "${candidate}" ] || continue
    [ -d "${candidate}" ] && {
      printf '%s' "${candidate}"
      return 0
    }
  done

  return 1
}

cross_target_python_libdir() {
  local triplet
  local python_root=""
  local candidate

  python_root="$(cross_target_python_root "$@" 2>/dev/null || true)"
  triplet="$(cross_target_triplet 2>/dev/null || true)"

  for candidate in \
    "${python_root:+${python_root}/lib}" \
    "/usr/local/lib" \
    "/usr/lib/${triplet}" \
    "/usr/lib"; do
    [ -n "${candidate}" ] || continue
    [ -d "${candidate}" ] && {
      printf '%s' "${candidate}"
      return 0
    }
  done

  return 1
}

cross_target_python_library() {
  local python_mm
  local triplet
  local python_root=""
  local candidate

  python_mm="$(cross_target_python_major_minor)" || return 1
  triplet="$(cross_target_triplet 2>/dev/null || true)"
  python_root="$(cross_target_python_root "$@" 2>/dev/null || true)"

  for candidate in \
    "${python_root:+${python_root}/lib/libpython${python_mm}.so}" \
    "${python_root:+${python_root}/lib/libpython${python_mm}.so.1.0}" \
    "/usr/local/lib/libpython${python_mm}.so" \
    "/usr/local/lib/libpython${python_mm}.so.1.0" \
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
  local python_root=""
  local candidate

  python_root="$(cross_target_python_root "$@" 2>/dev/null || true)"
  triplet="$(cross_target_triplet 2>/dev/null || true)"

  for candidate in \
    "${python_root:+${python_root}/lib/pkgconfig}" \
    "/usr/local/lib/pkgconfig" \
    "/usr/lib/${triplet}/pkgconfig" \
    "/usr/lib/pkgconfig"; do
    [ -n "${candidate}" ] || continue
    [ -d "${candidate}" ] && {
      printf '%s' "${candidate}"
      return 0
    }
  done

  return 1
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

cross_detect_distro_codename() {
  local distro=""

  if [ -n "${DISTRO:-}" ]; then
    printf '%s' "${DISTRO}"
    return 0
  fi

  if [ -r /etc/os-release ]; then
    distro="$(
      # shellcheck disable=SC1091
      . /etc/os-release
      printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    )"
    if [ -n "${distro}" ]; then
      printf '%s' "${distro}"
      return 0
    fi
  fi

  if command -v lsb_release >/dev/null 2>&1; then
    distro="$(lsb_release -cs 2>/dev/null || true)"
    if [ -n "${distro}" ]; then
      printf '%s' "${distro}"
      return 0
    fi
  fi

  printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-noble}}"
}

cross_prune_foreign_arch_apt_sources() {
  local keep_source="${1:-}"
  local existing_ports_source

  shopt -s nullglob
  for existing_ports_source in /etc/apt/sources.list.d/ubuntu-ports-*.sources; do
    [ -n "${keep_source}" ] && [ "${existing_ports_source}" = "${keep_source}" ] && continue
    rm -f "${existing_ports_source}"
  done
  shopt -u nullglob
}

cross_prepare_apt_sources_for_target() {
  local target_arch ports_sources

  cross_mode_requested || return 0

  target_arch="${TARGET_ARCH:-${TARGETARCH:-}}"
  [ -n "${target_arch}" ] || return 0

  if cross_build_enabled && cross_target_uses_ubuntu_ports; then
    ports_sources="/etc/apt/sources.list.d/ubuntu-ports-${target_arch}.sources"
    cross_prune_foreign_arch_apt_sources "${ports_sources}"
    cross_configure_foreign_arch_apt_sources
  else
    cross_prune_foreign_arch_apt_sources
  fi
}

cross_apt_update() {
  cross_prepare_apt_sources_for_target
  apt-get update "$@"
  _CROSS_ENV_APT_UPDATED=1
}

cross_configure_foreign_arch_apt_sources() {
  local target_arch build_arch distro ports_url host_sources ports_sources tmp existing_ports_source

  cross_build_enabled || return 0
  cross_target_uses_ubuntu_ports || return 0

  target_arch="$(cross_target_arch)"
  build_arch="$(cross_build_arch)"
  distro="$(cross_detect_distro_codename)"
  ports_url="$(cross_foreign_arch_ports_mirror_url)"
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

  cross_prune_foreign_arch_apt_sources "${ports_sources}"

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
  cross_prepare_apt_sources_for_target
}

cross_package_has_install_candidate() {
  local pkg="${1:-}"
  local candidate=""

  [ -n "${pkg}" ] || return 1

  # `apt-cache show` can return package metadata even when apt cannot install the
  # package on this release/architecture combination.
  candidate="$(apt-cache policy "${pkg}" 2>/dev/null | awk '/^[[:space:]]*Candidate:/ { print $2; exit }')"
  [ -n "${candidate}" ] && [ "${candidate}" != "(none)" ]
}

cross_resolve_target_package() {
  local pkg="$1"
  local target_arch
  target_arch="$(cross_target_arch)"

  if ! cross_build_enabled; then
    printf '%s' "${pkg}"
    return 0
  fi

  if cross_package_has_install_candidate "${pkg}:${target_arch}"; then
    printf '%s' "${pkg}:${target_arch}"
  else
    printf '%s' "${pkg}"
  fi
}

install_host_packages() {
  [ "$#" -gt 0 ] || return 0
  apt-get install -y --no-install-recommends "$@"
}

cross_filter_known_foreign_postinst_noise() {
  local line

  while IFS= read -r line; do
    case "${line}" in
      *"glib-compile-schemas: Exec format error"*|*"gio-querymodules: Exec format error"*|*"gdk-pixbuf-query-loaders: Exec format error"*)
        continue
        ;;
    esac
    printf '%s\n' "${line}"
  done
}

install_target_packages() {
  local pkg resolved
  local had_pipefail=0
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

  if cross_build_enabled; then
    case ":${SHELLOPTS:-}:" in
      *:pipefail:*) had_pipefail=1 ;;
    esac
    set -o pipefail
    apt-get install -y --no-install-recommends "${pkgs[@]}" 2>&1 | cross_filter_known_foreign_postinst_noise
    if [ "${had_pipefail}" -ne 1 ]; then
      set +o pipefail
    fi
    return 0
  fi

  apt-get install -y --no-install-recommends "${pkgs[@]}"
}

install_optional_target_packages() {
    local pkg

    [ "$#" -gt 0 ] || return 0

    for pkg in "$@"; do
        if ! install_target_packages "${pkg}"; then
            echo "Skipping optional target package ${pkg} because apt could not resolve it for $(cross_target_arch 2>/dev/null || echo target)."
        fi
    done
}

is_cross_riscv64() {
  command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled && \
  command -v cross_target_arch >/dev/null 2>&1 && [ "$(cross_target_arch)" = "riscv64" ]
}

is_cross_skip_csound() {
  command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled && \
  command -v cross_target_arch >/dev/null 2>&1 || return 1
  case "$(cross_target_arch)" in
    arm64|riscv64) return 0 ;;
    *) return 1 ;;
  esac
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
  local target_link_path dir

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
  gcc_major="${GCC_WANTED:-${GCC_VERSION:-16}}"
  gcc_major="$(version_major "${gcc_major}")"
  runtime_libdir="${gcc_prefix}/lib/gcc/${triplet}/${gcc_major}"
  cc="$(require_cross_gcc_tool gcc "${triplet}" 'cross compiler')" || return 1
  cxx="$(require_cross_gcc_tool g++ "${triplet}" 'cross compiler')" || return 1
  ar="$(require_cross_gcc_tool ar "${triplet}" 'cross binutils tool')" || return 1
  as="$(require_cross_gcc_tool as "${triplet}" 'cross binutils tool')" || return 1
  ld="$(require_cross_gcc_tool ld "${triplet}" 'cross binutils tool')" || return 1
  nm="$(require_cross_gcc_tool nm "${triplet}" 'cross binutils tool')" || return 1
  ranlib="$(require_cross_gcc_tool ranlib "${triplet}" 'cross binutils tool')" || return 1
  strip="$(require_cross_gcc_tool strip "${triplet}" 'cross binutils tool')" || return 1
  objcopy="$(require_cross_gcc_tool objcopy "${triplet}" 'cross binutils tool')" || return 1
  build_cc="$(resolve_build_gcc_tool gcc 2>/dev/null || true)"
  build_cxx="$(resolve_build_gcc_tool g++ 2>/dev/null || true)"
  build_ar="$(resolve_build_gcc_tool ar 2>/dev/null || true)"
  build_ranlib="$(resolve_build_gcc_tool ranlib 2>/dev/null || true)"

  export TARGET_ARCH="${target_arch}"
  export TARGETARCH="${target_arch}"
  export TARGETPLATFORM="linux/${target_arch}"
  export BUILDARCH="${build_arch}"
  export BUILDPLATFORM="linux/${build_arch}"
  export PYTHON_CROSS_STAGE_ROOT="${PYTHON_CROSS_STAGE_ROOT:-/opt/python-cross}"
  local _cross_python_active="${PYTHON_CROSS_ACTIVE_ROOT:-}"
  if [ -z "${_cross_python_active}" ] || [ ! -d "${_cross_python_active}/usr/local" ]; then
    local _cross_python_arch="${target_arch}"
    local _cross_python_stage="${PYTHON_CROSS_STAGE_ROOT:-/opt/python-cross}/${_cross_python_arch}"
    if [ -d "${_cross_python_stage}/usr/local" ]; then
      PYTHON_CROSS_ACTIVE_ROOT="${_cross_python_stage}"
    else
      PYTHON_CROSS_ACTIVE_ROOT="${PYTHON_CROSS_ACTIVE_ROOT:-/opt/python-target}"
    fi
  fi
  export PYTHON_CROSS_ACTIVE_ROOT
  export CROSS_TARGET_TRIPLET="${triplet}"
  export CROSS_TARGET_PROCESSOR="${processor}"
  export CROSS_RUST_TARGET="${rust_target}"

  dir="$(cross_bin_dir 2>/dev/null || true)"
  if [ -n "${dir}" ] && [ -d "${dir}" ]; then
    export PATH="${dir}:${PATH}"
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
  target_link_path=""
  for dir in \
    "${runtime_libdir}" \
    "${gcc_prefix}/${triplet}/lib" \
    "/usr/lib/${triplet}" \
    "/lib/${triplet}" \
    "/usr/${triplet}/lib"; do
    [ -d "${dir}" ] || continue
    target_link_path="${target_link_path:+${target_link_path}:}${dir}"
  done
  if [ -n "${target_link_path}" ]; then
    export LIBRARY_PATH="${target_link_path}${LIBRARY_PATH:+:${LIBRARY_PATH}}"
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
  local rust_target rustc_bin rust_binary_line rust_wrapper rust_wrapper_dir

  cross_build_enabled || return 0
  setup_linux_cross_env

  triplet="$(cross_target_triplet)"
  pkg_config_libdir="$(cross_pkg_config_libdir "${triplet}")"
  rust_target="$(cross_target_rust_triple)"
  rustc_bin="$(command -v rustc 2>/dev/null || true)"
  [ -n "${rustc_bin}" ] || rustc_bin="rustc"
  exe_wrapper=""
  # Some cross builds need to run target-side helpers during Meson setup. Reuse
  # an explicitly provided wrapper first, then fall back to the generic qemu
  # target-runner wrapper installed by pre-setup hooks.
  if [ -n "${MESON_EXE_WRAPPER:-}" ] && [ -x "${MESON_EXE_WRAPPER}" ]; then
    exe_wrapper="${MESON_EXE_WRAPPER}"
  else
    wrapper_candidate="/usr/local/bin/meson-$(cross_target_arch)-exe-wrapper"
    if [ -x "${wrapper_candidate}" ]; then
      exe_wrapper="${wrapper_candidate}"
    fi
  fi
  exe_wrapper_line=""
  if [ -n "${exe_wrapper}" ]; then
    exe_wrapper_line="exe_wrapper = '${exe_wrapper}'"
  fi

  # Meson's Rust cross sanity checks do not reliably infer the target triple
  # from the linker alone. Inject it only when the invocation does not already
  # specify --target so cargo-backed subprojects keep working.
  if [ -n "${rust_target}" ] && command -v make_meson_cross_rust_wrapper >/dev/null 2>&1; then
    rust_wrapper_dir="${MESON_RUST_TOOLCHAIN_DIR:-/tmp/meson-rust-toolchain}"
    rust_wrapper="$(make_meson_cross_rust_wrapper "${rust_wrapper_dir}/rustc-$(cross_target_arch)" "${rustc_bin}" "${rust_target}")"
    rust_binary_line="rust = '${rust_wrapper}'"
  else
    rust_binary_line="rust = '${rustc_bin}'"
  fi

  cat > "${path}" <<EOF
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR}'
strip = '${STRIP}'
${rust_binary_line}
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
    native_cc_wrapper="$(make_host_compiler_wrapper "${native_wrapper_dir}/native-cc" "${native_cc}" "${host_path}")"
    native_cc="${native_cc_wrapper}"
  fi

  if [ -n "${native_cxx}" ]; then
    native_cxx_wrapper="$(make_host_compiler_wrapper "${native_wrapper_dir}/native-cxx" "${native_cxx}" "${host_path}")"
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
