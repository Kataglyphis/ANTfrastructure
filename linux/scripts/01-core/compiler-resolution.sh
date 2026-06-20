#!/usr/bin/env bash
# compiler-resolution.sh — centralized host compiler resolution for media build scripts.
# Source this directly or through artifact-common.sh.
[ -n "${_COMPILER_RESOLUTION_SH_LOADED:-}" ] && return 0
_COMPILER_RESOLUTION_SH_LOADED=1
#
# Provides:
#   resolve_host_compiler_for_lang   — resolve host C/C++ compiler for the given language
#   prepare_host_compiler_wrapper    — create a host compiler wrapper script

# Resolve a host compiler for the given language (c or cxx).
# Returns the compiler path on stdout; falls back through resolve_build_gcc_tool,
# multiarch triplet-prefixed compilers, system compilers, and clang.
resolve_host_compiler_for_lang() {
  local lang="$1"
  local triplet=""
  local resolved=""

  if command -v resolve_build_gcc_tool >/dev/null 2>&1; then
    case "${lang}" in
      c)
        resolved="$(resolve_build_gcc_tool gcc 2>/dev/null || true)"
        [ -n "${resolved}" ] || resolved="$(resolve_build_gcc_tool cc 2>/dev/null || true)"
        ;;
      cxx)
        resolved="$(resolve_build_gcc_tool g++ 2>/dev/null || true)"
        [ -n "${resolved}" ] || resolved="$(resolve_build_gcc_tool c++ 2>/dev/null || true)"
        ;;
    esac
    [ -n "${resolved}" ] && { printf '%s' "${resolved}"; return 0; }
  fi

  if command -v build_deb_multiarch_triplet >/dev/null 2>&1; then
    triplet="$(build_deb_multiarch_triplet)"
  fi

  case "${lang}" in
    c)
      for candidate in \
        "/usr/bin/${triplet}-gcc" \
        /usr/bin/clang \
        /usr/bin/gcc \
        /usr/bin/cc; do
        [ -x "${candidate}" ] && { printf '%s' "${candidate}"; return 0; }
      done
      command -v gcc 2>/dev/null || command -v cc 2>/dev/null || true
      ;;
    cxx)
      for candidate in \
        "/usr/bin/${triplet}-g++" \
        /usr/bin/clang++ \
        /usr/bin/g++ \
        /usr/bin/c++; do
        [ -x "${candidate}" ] && { printf '%s' "${candidate}"; return 0; }
      done
      command -v g++ 2>/dev/null || command -v c++ 2>/dev/null || true
      ;;
    *)
      printf 'ERROR: unknown compiler language "%s"\n' "${lang}" >&2
      return 1
      ;;
  esac
}

# Create a host compiler wrapper in the given directory.
# If make_named_host_compiler_wrapper is available, delegates to it.
# Otherwise creates the wrapper manually.
prepare_host_compiler_wrapper() {
  local compiler="$1"
  local wrapper_name="${2:-host-gcc}"
  local wrapper_dir="${3:-${TMPDIR:-/tmp}/host-toolchain-$$}"
  local wrapper_path="${wrapper_dir}/${wrapper_name}"

  if command -v make_named_host_compiler_wrapper >/dev/null 2>&1; then
    make_named_host_compiler_wrapper "${wrapper_dir}" "${wrapper_name}" "${compiler}" >/dev/null
    printf '%s' "${wrapper_path}"
    return 0
  fi

  mkdir -p "${wrapper_dir}"
  cat > "${wrapper_path}" <<EOF
#!/bin/sh
exec "${compiler}" "\$@"
EOF
  chmod +x "${wrapper_path}"
  printf '%s' "${wrapper_path}"
}

# Derive the C++ compiler path from a C compiler path by replacing the
# -gcc suffix with -g++. Returns empty if the derived path is not executable.
derive_cxx_from_cc() {
  local cc="$1"
  local cxx
  cxx="$(printf '%s' "${cc}" | sed 's/-gcc$/-g++/')"
  [ -x "${cxx}" ] && printf '%s' "${cxx}"
}

# Resolve both CC and CXX for a target architecture. Expects TARGET_ARCH or
# TARGETARCH to be set. Exports CC and CXX on success. Returns 1 if either
# compiler cannot be found.
resolve_cross_cc_cxx_for_arch() {
  local arch="${1:-${TARGET_ARCH:-${TARGETARCH:-}}}"
  local triplet cc cxx

  [ -n "${arch}" ] || return 1

  if command -v arch_deb_multiarch_triplet_for >/dev/null 2>&1; then
    triplet="$(arch_deb_multiarch_triplet_for "${arch}")" || return 1
  else
    case "${arch}" in
      amd64) triplet="x86_64-linux-gnu" ;;
      arm64) triplet="aarch64-linux-gnu" ;;
      riscv64) triplet="riscv64-linux-gnu" ;;
      *) return 1 ;;
    esac
  fi

  local gcc_prefix="/opt/gcc-${GCC_VERSION:-16.1.0}"
  cc="${gcc_prefix}/bin/${triplet}-gcc"
  cxx="${gcc_prefix}/bin/${triplet}-g++"

  [ -x "${cc}" ] || return 1
  [ -x "${cxx}" ] || cxx="$(derive_cxx_from_cc "${cc}")"
  [ -x "${cxx}" ] || return 1

  export CC="${cc}" CXX="${cxx}"
}

# Fix broken libstdc++.so symlinks that point to the wrong architecture.
# The SDK image's apt packages may create symlinks in /usr/lib/<triplet>/
# that point to the host (amd64) libstdc++ instead of the target arch one.
fix_libstdcxx_symlink() {
  local arch="${1:-${TARGET_ARCH:-${TARGETARCH:-}}}"
  local triplet gcc_lib sys_lib

  [ -n "${arch}" ] || return 0
  [ "${arch}" = "amd64" ] && return 0

  if command -v arch_deb_multiarch_triplet_for >/dev/null 2>&1; then
    triplet="$(arch_deb_multiarch_triplet_for "${arch}")" || return 0
  else
    case "${arch}" in
      arm64) triplet="aarch64-linux-gnu" ;;
      riscv64) triplet="riscv64-linux-gnu" ;;
      *) return 0 ;;
    esac
  fi

  sys_lib="/usr/lib/${triplet}/libstdc++.so"
  gcc_lib="/opt/gcc-${GCC_VERSION:-16.1.0}/${triplet}/lib64/libstdc++.so"

  [ -L "${sys_lib}" ] || return 0
  [ -f "${gcc_lib}" ] || return 0

  # Only fix if the symlink currently points to the wrong arch
  local current_target
  current_target="$(readlink -f "${sys_lib}" 2>/dev/null || true)"
  case "${current_target}" in
    */${triplet}/*) return 0 ;;  # Already correct
  esac

  ln -sf "${gcc_lib}" "${sys_lib}"
}
