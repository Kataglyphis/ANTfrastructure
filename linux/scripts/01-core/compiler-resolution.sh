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
