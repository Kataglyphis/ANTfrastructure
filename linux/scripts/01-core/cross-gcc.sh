# shellcheck shell=bash
# Source-only helper -- do not execute directly.
# cross-gcc.sh - GCC toolchain detection helpers.
# Sourced by cross-env.sh.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This script is meant to be sourced, not executed" >&2
  exit 1
fi

[ -z "${_CROSS_GCC_LOADED:-}" ] || return 0
_CROSS_GCC_LOADED=1

# SSOT-of-the-default for the source-built GCC toolchain inside the cross-env
# sourcing pass (backlog DUP2). cross-env.sh hard-sources this file (no `[ -f ]`
# guard), so every consumer of that pass can call these helpers instead of
# re-spelling the version.
#
# The fallback literal below stays an inline literal ON PURPOSE and must NOT be
# routed through common.sh / versions.env: a mount audit of the RUNs that bind
# cross-gcc.sh found two that mount NEITHER (Dockerfile.toolchain's RUN at line
# 266 and Dockerfile.media's RUN at line 414), so there GCC_VERSION can only
# come from the stage ARG/ENV and the literal IS the last-resort value. Keeping
# it in the `VAR:-literal` expansion form is also what lets
# verify-arg-consistency.sh's "GCC toolchain default literal check" pin it to
# versions.env, which is how the ~25 sibling copies across linux/ are kept from
# drifting on the next GCC bump.
gcc_toolchain_version() {
  printf '%s' "${GCC_VERSION:-16.2.0}"
}

gcc_toolchain_prefix() {
  printf '%s' "/opt/gcc-$(gcc_toolchain_version)"
}

gcc_toolchain_bindir() {
  printf '%s' "$(gcc_toolchain_prefix)/bin"
}

# Point clang at the source-built GCC (headers, libstdc++, crt). Exports the
# --gcc-toolchain flags only; CC/CXX selection stays with the caller, and GCC
# itself rejects the flag, so this is a no-op unless clang is in use.
# Docs: docs/linux-cross-builds.md#operational-env-knobs-not-versionsenv
export_clang_gcc_toolchain_env() {
  : "${CROSS_GCC_TOOLCHAIN_PATH:=$(gcc_toolchain_prefix)}"
  local root="${CROSS_GCC_TOOLCHAIN_PATH}"
  case "$(basename "${CC:-}")" in clang*) ;; *) return 0 ;; esac
  if [ ! -d "$root" ]; then
    printf 'export_clang_gcc_toolchain_env: no GCC toolchain at %s; clang will use its own discovery\n' "$root" >&2
    return 0
  fi

  local lib=""
  [ -d "$root/lib64" ] && lib="$root/lib64" || { [ -d "$root/lib" ] && lib="$root/lib"; }

  export CFLAGS="--gcc-toolchain=${root} ${CFLAGS:-}"
  export CXXFLAGS="--gcc-toolchain=${root} ${CXXFLAGS:-}"
  local triple
  for triple in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu riscv64gc-unknown-linux-gnu i686-unknown-linux-gnu; do
    export "CFLAGS_${triple//-/_}=--gcc-toolchain=${root}"
    export "CXXFLAGS_${triple//-/_}=--gcc-toolchain=${root}"
  done

  if [ -n "$lib" ]; then
    export LDFLAGS="-L${lib} -Wl,-rpath,${lib} --gcc-toolchain=${root} ${LDFLAGS:-}"
  else
    export LDFLAGS="--gcc-toolchain=${root} ${LDFLAGS:-}"
  fi
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

# Resolve a GCC cross archive tool (ar, ranlib, etc.) for the current cross target.
# Looks for <triplet>-gcc-<tool> first, then falls back to <triplet>-<tool>.
resolve_cross_archive_tool() {
  local tool="$1"
  local triplet="${2:-${CROSS_TARGET_TRIPLET:-}}"
  local preferred=""
  local fallback=""
  local resolved=""

  [ -n "${triplet}" ] || {
    if command -v cross_target_triplet >/dev/null 2>&1; then
      triplet="$(cross_target_triplet)" || return 1
    else
      return 1
    fi
  }

  preferred="${triplet}-gcc-${tool}"
  fallback="${triplet}-${tool}"

  resolved="$(command -v "${preferred}" 2>/dev/null || true)"
  if [ -n "${resolved}" ]; then
    printf '%s' "${resolved}"
    return 0
  fi

  resolved="$(command -v "${fallback}" 2>/dev/null || true)"
  if [ -n "${resolved}" ]; then
    printf '%s' "${resolved}"
    return 0
  fi

  return 1
}
