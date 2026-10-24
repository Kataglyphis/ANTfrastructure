#!/usr/bin/env bash
# Host and cross compiler resolution for the media build scripts.
[ -n "${_COMPILER_RESOLUTION_SH_LOADED:-}" ] && return 0
_COMPILER_RESOLUTION_SH_LOADED=1

_COMPILER_RESOLUTION_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Some callers source this file standalone, so load its two dependencies here.
# shellcheck disable=SC1090,SC1091
[ -n "${_PLATFORM_SH_LOADED:-}" ] || \
  { [ -f "${_COMPILER_RESOLUTION_SH_DIR}/platform.sh" ] && source "${_COMPILER_RESOLUTION_SH_DIR}/platform.sh"; }
# shellcheck disable=SC1090,SC1091
[ -n "${_CROSS_GCC_LOADED:-}" ] || \
  { [ -f "${_COMPILER_RESOLUTION_SH_DIR}/cross-gcc.sh" ] && source "${_COMPILER_RESOLUTION_SH_DIR}/cross-gcc.sh"; }

# resolve_host_compiler_for_lang <c|cxx>: prints the path.
resolve_host_compiler_for_lang() {
  local lang="$1" compiler alternate clang_compiler candidate
  local triplet="" resolved=""
  case "${lang}" in
    c) compiler=gcc; alternate=cc; clang_compiler=clang ;;
    cxx) compiler=g++; alternate=c++; clang_compiler=clang++ ;;
    *) printf 'ERROR: unknown compiler language "%s"\n' "${lang}" >&2; return 1 ;;
  esac

  if command -v resolve_build_gcc_tool >/dev/null 2>&1; then
    resolved="$(resolve_build_gcc_tool "${compiler}" 2>/dev/null || true)"
    [ -n "${resolved}" ] || resolved="$(resolve_build_gcc_tool "${alternate}" 2>/dev/null || true)"
    [ -n "${resolved}" ] && { printf '%s' "${resolved}"; return 0; }
  fi

  if command -v build_deb_multiarch_triplet >/dev/null 2>&1; then
    triplet="$(build_deb_multiarch_triplet)"
  fi
  for candidate in \
    "/usr/bin/${triplet}-${compiler}" \
    "/usr/bin/${clang_compiler}" \
    "/usr/bin/${compiler}" \
    "/usr/bin/${alternate}"; do
    [ -x "${candidate}" ] && { printf '%s' "${candidate}"; return 0; }
  done
  command -v "${compiler}" 2>/dev/null || command -v "${alternate}" 2>/dev/null || true
}

# prepare_host_compiler_wrapper <compiler> [name] [dir]: prints the wrapper path.
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

# Prints the -g++ sibling, or nothing (still rc 0) when it is not executable.
derive_cxx_from_cc() {
  local cc="$1"
  local cxx
  cxx="$(printf '%s' "${cc}" | sed 's/-gcc$/-g++/')"
  [ -x "${cxx}" ] || return 0
  printf '%s' "${cxx}"
}

# resolve_cross_cc_cxx_for_arch [arch]: exports CC and CXX, or returns 1.
resolve_cross_cc_cxx_for_arch() {
  local arch
  arch="$(default_target_arch "${1:-}")"
  local triplet cc cxx

  [ -n "${arch}" ] || return 1

  triplet="$(arch_deb_multiarch_triplet_for "${arch}")" || return 1

  local gcc_prefix
  gcc_prefix="$(gcc_toolchain_prefix)"
  cc="${gcc_prefix}/bin/${triplet}-gcc"
  cxx="${gcc_prefix}/bin/${triplet}-g++"

  [ -x "${cc}" ] || return 1
  [ -x "${cxx}" ] || cxx="$(derive_cxx_from_cc "${cc}")"
  [ -x "${cxx}" ] || return 1

  export CC="${cc}" CXX="${cxx}"
}

_compiler_target_is_foreign() {
  [ -n "$1" ] || return 1
  if [ "$1" != "$(build_arch_oci 2>/dev/null || echo amd64)" ]; then return 0; fi
  return 1
}

# apt packages can leave /usr/lib/<triplet>/libstdc++.so pointing at the host arch's library.
fix_libstdcxx_symlink() {
  local arch
  arch="$(default_target_arch "${1:-}")"
  local triplet gcc_lib sys_lib

  _compiler_target_is_foreign "${arch}" || return 0

  triplet="$(arch_deb_multiarch_triplet_for "${arch}")" || return 0

  sys_lib="/usr/lib/${triplet}/libstdc++.so"
  gcc_lib="$(gcc_toolchain_prefix)/${triplet}/lib64/libstdc++.so"

  [ -L "${sys_lib}" ] || return 0
  [ -f "${gcc_lib}" ] || return 0

  local current_target
  current_target="$(readlink -f "${sys_lib}" 2>/dev/null || true)"
  case "${current_target}" in
    */${triplet}/*) return 0 ;;  # Already correct
  esac

  ln -sf "${gcc_lib}" "${sys_lib}"
}

# The pretty-printer sorts after its library, so exclude it before version ordering.
_target_gcc_libstdcxx() {
  local triplet="$1" root="${2:-/opt}" candidate
  for candidate in "${root}"/gcc-*/"${triplet}"/{lib64,lib}/libstdc++.so.6.*; do
    case "${candidate}" in *.py) continue ;; esac
    [ -e "${candidate}" ] || continue
    printf '%s\n' "${candidate}"
  done | sort -V | tail -1
}

# Pins libstdc++.so and .so.6 to GCC's superset: the multiarch copy is often wrong-arch or lacks newer GLIBCXX; always rc 0.
pin_target_libstdcxx() {
  local arch
  arch="$(default_target_arch "${1:-}")"
  _compiler_target_is_foreign "${arch}" || return 0

  local triplet=""
  triplet="$(deb_multiarch_triplet_best_effort "${arch}")" || return $?
  case "${arch}" in
    arm64)   [ -n "${triplet}" ] || triplet="aarch64-linux-gnu" ;;
    riscv64) [ -n "${triplet}" ] || triplet="riscv64-linux-gnu" ;;
  esac
  [ -n "${triplet}" ] || return 0
  [ -d "/usr/lib/${triplet}" ] || return 0

  local gcc_lsx
  gcc_lsx="$(_target_gcc_libstdcxx "${triplet}")"
  if [ -n "${gcc_lsx}" ]; then
    ln -sf "${gcc_lsx}" "/usr/lib/${triplet}/libstdc++.so.6"
    ln -sf "${gcc_lsx}" "/usr/lib/${triplet}/libstdc++.so"
    echo "Cross: pinned /usr/lib/${triplet}/libstdc++.so{,.6} -> ${gcc_lsx} (GCC target-arch superset, has newer GLIBCXX)"
  else
    echo "WARN: no target-arch GCC libstdc++ found under /opt/gcc-*/${triplet}/; C++ cross link may fail" >&2
  fi
  return 0
}
