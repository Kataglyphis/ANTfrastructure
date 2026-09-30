# shellcheck shell=bash
# GCC toolchain detection helpers, sourced by cross-env.sh.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This script is meant to be sourced, not executed" >&2
  exit 1
fi

[ -z "${_CROSS_GCC_LOADED:-}" ] || return 0
_CROSS_GCC_LOADED=1

# Inline literal on purpose: some RUNs mount no versions.env, and verify-arg-consistency.sh pins this `:-` form.
gcc_toolchain_version() {
  printf '%s' "${GCC_VERSION:-16.2.0}"
}

gcc_toolchain_prefix() {
  printf '%s' "/opt/gcc-$(gcc_toolchain_version)"
}

gcc_toolchain_bindir() {
  printf '%s' "$(gcc_toolchain_prefix)/bin"
}

# The prefix on this machine with a usable GCC (crtbeginS.o present); 1 and no output when none, never an empty path.
gcc_toolchain_resolve_prefix() {
  local candidate
  for candidate in "${MYPROJECT_GCC_TOOLCHAIN_PATH:-}" "${GCC_PREFIX:-}"; do
    if [ -n "${candidate}" ] && [ -d "${candidate}" ]; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  candidate="$(gcc_toolchain_prefix)"
  if compgen -G "${candidate}/lib/gcc/*/*/crtbeginS.o" >/dev/null 2>&1; then
    printf '%s' "${candidate}"
    return 0
  fi
  local newest=""
  for candidate in /opt/gcc-*; do
    [ -d "${candidate}" ] || continue
    compgen -G "${candidate}/lib/gcc/*/*/crtbeginS.o" >/dev/null 2>&1 || continue
    newest="${candidate}"
  done
  if [ -n "${newest}" ]; then
    printf '%s' "${newest}"
    return 0
  fi
  return 1
}

# Consumer-facing (no caller here): --gcc-toolchain flags for clang only. docs/linux-cross-builds.md#operational-env-knobs-not-versionsenv
export_clang_gcc_toolchain_env() {
  : "${CROSS_GCC_TOOLCHAIN_PATH:=$(gcc_toolchain_resolve_prefix || gcc_toolchain_prefix)}"
  local root="${CROSS_GCC_TOOLCHAIN_PATH}"
  case "$(basename "${CC:-}")" in clang*) ;; *) return 0 ;; esac
  if [ ! -d "$root" ]; then
    printf 'export_clang_gcc_toolchain_env: no GCC toolchain at %s; clang will use its own discovery\n' "$root" >&2
    return 0
  fi

  local lib=""
  if [ -d "$root/lib64" ]; then
    lib="$root/lib64"
  elif [ -d "$root/lib" ]; then
    lib="$root/lib"
  fi

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

# Prefers <triplet>-gcc-<tool> over <triplet>-<tool>.
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
