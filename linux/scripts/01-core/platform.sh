#!/usr/bin/env bash
# platform.sh - small, side-effect-free platform helpers

[ -n "${_PLATFORM_SH_LOADED:-}" ] && return 0
_PLATFORM_SH_LOADED=1

# The one truthiness predicate; _bool_truthy and ubuntu_mirror_is_truthy delegate here (this leaf loads first).
is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

arch_normalize() {
  case "$1" in
    amd64|x86_64|x64) printf '%s' "amd64" ;;
    arm64|aarch64) printf '%s' "arm64" ;;
    i386|i486|i586|i686|386) printf '%s' "386" ;;
    riscv64|riscv|rv64*) printf '%s' "riscv64" ;;
    *) printf '%s' "$1" ;;
  esac
}

arch_uname_name_for() {
  case "$(arch_normalize "$1")" in
    amd64) printf '%s' "x86_64" ;;
    arm64) printf '%s' "aarch64" ;;
    386) printf '%s' "i386" ;;
    riscv64) printf '%s' "riscv64" ;;
    *) printf '%s' "$1" ;;
  esac
}

arch_deb_multiarch_triplet_for() {
  case "$(arch_normalize "$1")" in
    amd64) printf '%s' "x86_64-linux-gnu" ;;
    arm64) printf '%s' "aarch64-linux-gnu" ;;
    386) printf '%s' "i386-linux-gnu" ;;
    riscv64) printf '%s' "riscv64-linux-gnu" ;;
    *) return 1 ;;
  esac
}

arch_cmake_system_processor_for() {
  case "$(arch_normalize "$1")" in
    amd64) printf '%s' "x86_64" ;;
    arm64) printf '%s' "aarch64" ;;
    386) printf '%s' "i686" ;;
    riscv64) printf '%s' "riscv64" ;;
    *) printf '%s' "$(arch_normalize "$1")" ;;
  esac
}

arch_rust_target_triple_for() {
  case "$(arch_normalize "$1")" in
    amd64) printf '%s' "x86_64-unknown-linux-gnu" ;;
    arm64) printf '%s' "aarch64-unknown-linux-gnu" ;;
    386) printf '%s' "i686-unknown-linux-gnu" ;;
    riscv64) printf '%s' "riscv64gc-unknown-linux-gnu" ;;
    *) return 1 ;;
  esac
}

arch_android_abi_for() {
  case "$(arch_normalize "$1")" in
    amd64) printf '%s' "x86_64" ;;
    arm64) printf '%s' "arm64-v8a" ;;
    386) printf '%s' "x86" ;;
    riscv64) printf '%s' "riscv64" ;;
    *) return 1 ;;
  esac
}

arch_cpu_family_for() {
  case "$(arch_normalize "$1")" in
    amd64) printf '%s' "x86_64" ;;
    arm64) printf '%s' "aarch64" ;;
    386) printf '%s' "x86" ;;
    riscv64) printf '%s' "riscv64" ;;
    *) printf '%s' "$(arch_normalize "$1")" ;;
  esac
}

arch_cpu_for() {
  case "$(arch_normalize "$1")" in
    386) printf '%s' "i686" ;;
    *) arch_cpu_family_for "$1" ;;
  esac
}

arch_linux_platform_tag_for() {
  case "$(arch_normalize "$1")" in
    amd64) printf '%s' "linux_x86_64" ;;
    arm64) printf '%s' "linux_aarch64" ;;
    386) printf '%s' "linux_i686" ;;
    riscv64) printf '%s' "linux_riscv64" ;;
    *) return 1 ;;
  esac
}

arch_from_target_triple() {
  case "${1%%-*}" in
    x86_64|amd64) printf '%s' "amd64" ;;
    aarch64|arm64) printf '%s' "arm64" ;;
    riscv64|riscv64gc) printf '%s' "riscv64" ;;
    i686|i386|x86) printf '%s' "386" ;;
    *) return 1 ;;
  esac
}

# readelf "Machine:" substring per arch; unlike gcc -dumpmachine it tells a native compiler from a cross one.
arch_elf_machine_grep_for() {
  case "$(arch_normalize "$1")" in
    amd64) printf '%s' "X86-64" ;;
    arm64) printf '%s' "AArch64" ;;
    386) printf '%s' "Intel 80386" ;;
    riscv64) printf '%s' "RISC-V" ;;
    *) return 1 ;;
  esac
}

# Never executes the binary, so it works on foreign-arch files.
elf_machine_name() {
  local file="$1"

  command -v readelf >/dev/null 2>&1 || return 1
  [ -r "${file}" ] || return 1
  LC_ALL=C readelf -h "${file}" 2>/dev/null \
    | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p' \
    | head -n1
}

# Exits (not returns) on an ELF arch mismatch; only warns when the check cannot run.
assert_elf_arch() {
  local bin="$1" arch="$2" expected_pattern machine

  expected_pattern="$(arch_elf_machine_grep_for "${arch}")" || {
    printf 'WARN: no ELF pattern for arch %s; skipping ELF check\n' "${arch}" >&2
    return 0
  }

  command -v readelf >/dev/null 2>&1 || {
    printf 'WARN: readelf missing; skipping ELF check\n' >&2
    return 0
  }

  machine="$(elf_machine_name "${bin}")"
  [ -n "${machine}" ] || {
    printf 'ERROR: cannot read ELF machine of %s\n' "${bin}" >&2
    exit 1
  }

  case "${machine}" in
    *"${expected_pattern}"*)
      printf 'ELF arch OK: %s Machine=%s matches %s\n' "${bin}" "${machine}" "${arch}"
      ;;
    *)
      printf 'ERROR: ELF arch MISMATCH %s Machine=%s expected %s for %s\n' \
        "${bin}" "${machine}" "${expected_pattern}" "${arch}" >&2
      exit 1
      ;;
  esac
}

# DT_NEEDED walk primitives

# Direct DT_NEEDED sonames in link order, cross-safe via objdump; never fails, as callers treat it as best-effort.
elf_needed_sonames() {
  local file="${1:-}"
  [ -e "${file}" ] || return 0
  if command -v objdump >/dev/null 2>&1; then
    # objdump exits non-zero on non-ELF input, which pipefail would surface.
    { objdump -p "${file}" 2>/dev/null || true; } | awk '/NEEDED/{print $2}'
  elif command -v readelf >/dev/null 2>&1; then
    { LC_ALL=C readelf -d "${file}" 2>/dev/null || true; } \
      | sed -n 's/.*(NEEDED)[^[]*\[\(.*\)\].*/\1/p'
  fi
  return 0
}

# _elf_soname_resolves <soname> [libdir...]: found in the given dirs, the system lib dirs or the ldconfig cache.
_elf_soname_resolves() {
  local so_name="$1" dir
  shift
  for dir in "$@" /usr/lib /lib /usr/lib/*-linux-gnu* /usr/local/lib/*-linux-gnu*; do
    [ -d "${dir}" ] || continue
    [ -f "${dir}/${so_name}" ] && return 0
  done
  # No grep -q: its early exit can SIGPIPE ldconfig, and pipefail would call a found soname missing.
  [ -n "$({ ldconfig -p 2>/dev/null || true; } | grep -F " ${so_name} " || true)" ] && return 0
  return 1
}

# Unresolved NEEDED sonames, static and cross-safe; --transitive uses ldd and so needs a runnable binary. Never fails.
elf_unresolved_needed() {
  local transitive=0
  if [ "${1:-}" = "--transitive" ]; then
    transitive=1
    shift
  fi
  local file="${1:-}"
  shift || true
  if [ "${transitive}" = "1" ] && command -v ldd >/dev/null 2>&1; then
    local extra="" dir
    for dir in "$@"; do
      extra="${extra:+${extra}:}${dir}"
    done
    { LD_LIBRARY_PATH="${extra:+${extra}:}${LD_LIBRARY_PATH:-}" ldd "${file}" 2>/dev/null || true; } \
      | awk '/=> not found/{print $1}' | sort -u
    return 0
  fi
  local so_name
  while IFS= read -r so_name; do
    [ -n "${so_name}" ] || continue
    _elf_soname_resolves "${so_name}" "$@" || printf '%s\n' "${so_name}"
  done < <(elf_needed_sonames "${file}")
  return 0
}

arch_list_csv_normalize() {
  local raw_list="$1"
  local raw_arch normalized_arch
  local -a normalized_arches=()
  local old_ifs="${IFS}"

  IFS=', '
  for raw_arch in ${raw_list}; do
    [ -n "${raw_arch}" ] || continue
    normalized_arch="$(arch_normalize "${raw_arch}")"
    case "${normalized_arch}" in
      amd64|arm64|386|riscv64) normalized_arches+=("${normalized_arch}") ;;
      *) IFS="${old_ifs}"; return 1 ;;
    esac
  done
  IFS="${old_ifs}"

  [ "${#normalized_arches[@]}" -gt 0 ] || return 1
  local _arch _csv="" _sep=""
  for _arch in "${normalized_arches[@]}"; do
    _csv+="${_sep}${_arch}"
    _sep=","
  done
  printf '%s' "${_csv}"
}

# The one target-arch fallback chain: argument, TARGET_ARCH, TARGETARCH, ARCH; empty when none is set.
default_target_arch() {
  printf '%s' "${1:-${TARGET_ARCH:-${TARGETARCH:-${ARCH:-}}}}"
}

cross_targets_effective_raw() {
  printf '%s' "${VERIFY_CROSS_TARGETS:-${CROSS_TARGETS:-${ARCH:-${TARGETARCH:-${TARGET_ARCH:-}}}}}"
}

_platform_raw_target_arch() {
  canonical_resolve_arch "${TARGET_ARCH:-${TARGETARCH:-}}"
}

canonical_resolve_arch() {
  local raw="${1:-}"

  if [ -n "${raw}" ]; then
    printf '%s' "${raw}"
    return 0
  fi

  if [ -n "${TARGETARCH:-}" ]; then
    printf '%s' "${TARGETARCH}"
    return 0
  fi

  if command -v dpkg >/dev/null 2>&1; then
    raw="$(dpkg --print-architecture 2>/dev/null || true)"
  fi
  if [ -z "${raw}" ]; then
    raw="$(uname -m 2>/dev/null || echo unknown)"
  fi
  printf '%s' "${raw}"
}

canonical_target_arch() {
  local raw="${1:-}"
  local resolved
  resolved="$(canonical_resolve_arch "${raw}")"
  arch_normalize "${resolved}" || return 1
}

_platform_raw_build_arch() {
  local raw="${BUILDARCH:-}"
  if [ -z "${raw}" ] && [ -n "${BUILDPLATFORM:-}" ]; then
    raw="${BUILDPLATFORM##*/}"
  fi
  if [ -z "${raw}" ] && command -v dpkg >/dev/null 2>&1; then
    raw="$(dpkg --print-architecture 2>/dev/null || true)"
  fi
  if [ -z "${raw}" ]; then
    raw="$(uname -m 2>/dev/null || echo unknown)"
  fi
  printf '%s' "${raw}"
}

arch_oci() {
  # Returns OCI/Docker style arch names for the build target.
  arch_normalize "$(_platform_raw_target_arch)"
}

build_arch_oci() {
  # Returns OCI/Docker style arch names for the machine executing the build.
  arch_normalize "$(_platform_raw_build_arch)"
}

# Platform of every cross stage; not host-derived, since an arm64 host still builds amd64 images by default.
cross_build_platform() { printf '%s' "${CROSS_BUILD_PLATFORM:-linux/amd64}"; }

android_build_host_supported() {
  [ "$(build_arch_oci)" = "amd64" ]
}

android_require_amd64_build_host() {
  local scope="${1:-Android build}"

  if android_build_host_supported; then
    return 0
  fi

  printf 'Skipping %s on non-amd64 build host\n' "${scope}"
  return 1
}

deb_multiarch_triplet() {
  arch_deb_multiarch_triplet_for "$(arch_oci)" || printf '%s' ""
}

build_deb_multiarch_triplet() {
  arch_deb_multiarch_triplet_for "$(build_arch_oci)" || printf '%s' ""
}

cmake_system_processor() {
  arch_cmake_system_processor_for "$(arch_oci)"
}

rust_target_triple() {
  arch_rust_target_triple_for "$(arch_oci)" || printf '%s' ""
}

rust_target_triple_for_arch() {
  arch_rust_target_triple_for "$1"
}

android_abi_for_arch() {
  arch_android_abi_for "$1"
}

# The /opt/android ABI follows the target, never the build host. docs/linux-cross-builds.md#the-android-abi-is-a-target-not-the-build-host
arch_for_android_abi() {
  case "$1" in
    arm64-v8a) printf '%s' "arm64" ;;
    x86_64)    printf '%s' "amd64" ;;
    x86)       printf '%s' "386" ;;
    riscv64)   printf '%s' "riscv64" ;;
    *) return 1 ;;
  esac
}

android_target_arch() {
  if [ -n "${ANDROID_TARGET_ABI:-}" ]; then
    arch_for_android_abi "${ANDROID_TARGET_ABI}" && return 0
  fi
  arch_oci
}

android_target_abi() {
  if [ -n "${ANDROID_TARGET_ABI:-}" ]; then
    printf '%s' "${ANDROID_TARGET_ABI}"
    return 0
  fi
  android_abi_for_arch "$(android_target_arch)" || printf '%s' ""
}

android_min_api_level_for_arch() {
  case "$(arch_normalize "$1")" in
    riscv64) printf '%s' "35" ;;
    *) printf '%s' "34" ;;
  esac
}

android_effective_api_level_for_arch() {
  local arch="$1"
  local requested_api="${2:-34}"
  local min_api

  min_api="$(android_min_api_level_for_arch "${arch}")"
  if [ "${requested_api}" -lt "${min_api}" ]; then
    printf '%s' "${min_api}"
    return 0
  fi

  printf '%s' "${requested_api}"
}

android_raise_api_level_if_needed() {
  local arch="$1"
  local requested_api="${2:-34}"
  local scope="${3:-Android build}"
  local effective_api

  effective_api="$(android_effective_api_level_for_arch "${arch}" "${requested_api}")"
  if [ "${effective_api}" != "${requested_api}" ]; then
    printf 'Raising Android API level from %s to %s for %s (%s)\n' \
      "${requested_api}" "${effective_api}" "${arch}" "${scope}" >&2
  fi

  printf '%s' "${effective_api}"
}

version_major() {
  local version="${1:-}"

  version="${version%%.*}"
  [ -n "${version}" ] || return 1
  printf '%s' "${version}"
}

version_major_minor() {
  local version="${1:-}"

  case "${version}" in
    *.*.*) printf '%s' "${version%.*}" ;;
    *.*) printf '%s' "${version}" ;;
    *) return 1 ;;
  esac
}
