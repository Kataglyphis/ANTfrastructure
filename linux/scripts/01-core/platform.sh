#!/usr/bin/env bash
# platform.sh - small, side-effect-free platform helpers

_platform_normalize_arch() {
  case "$1" in
    amd64|x86_64) printf '%s' "amd64" ;;
    arm64|aarch64) printf '%s' "arm64" ;;
    i386|i486|i586|i686|386) printf '%s' "386" ;;
    riscv64|riscv|rv64*) printf '%s' "riscv64" ;;
    *) printf '%s' "$1" ;;
  esac
}

_platform_raw_target_arch() {
  local raw="${TARGET_ARCH:-${TARGETARCH:-}}"
  if [ -n "${raw}" ]; then
    printf '%s' "${raw}"
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
  _platform_normalize_arch "$(_platform_raw_target_arch)"
}

build_arch_oci() {
  # Returns OCI/Docker style arch names for the machine executing the build.
  _platform_normalize_arch "$(_platform_raw_build_arch)"
}

is_amd64_arch() {
  [ "$(arch_oci)" = "amd64" ]
}

is_amd64_build_arch() {
  [ "$(build_arch_oci)" = "amd64" ]
}

deb_multiarch_triplet() {
  case "$(arch_oci)" in
    amd64) printf '%s' "x86_64-linux-gnu" ;;
    arm64) printf '%s' "aarch64-linux-gnu" ;;
    386) printf '%s' "i386-linux-gnu" ;;
    riscv64) printf '%s' "riscv64-linux-gnu" ;;
    *) printf '%s' "" ;;
  esac
}

build_deb_multiarch_triplet() {
  case "$(build_arch_oci)" in
    amd64) printf '%s' "x86_64-linux-gnu" ;;
    arm64) printf '%s' "aarch64-linux-gnu" ;;
    386) printf '%s' "i386-linux-gnu" ;;
    riscv64) printf '%s' "riscv64-linux-gnu" ;;
    *) printf '%s' "" ;;
  esac
}

cmake_system_processor() {
  case "$(arch_oci)" in
    amd64) printf '%s' "x86_64" ;;
    arm64) printf '%s' "aarch64" ;;
    386) printf '%s' "i686" ;;
    riscv64) printf '%s' "riscv64" ;;
    *) printf '%s' "$(arch_oci)" ;;
  esac
}

rust_target_triple() {
  case "$(arch_oci)" in
    amd64) printf '%s' "x86_64-unknown-linux-gnu" ;;
    arm64) printf '%s' "aarch64-unknown-linux-gnu" ;;
    386) printf '%s' "i686-unknown-linux-gnu" ;;
    riscv64) printf '%s' "riscv64gc-unknown-linux-gnu" ;;
    *) printf '%s' "" ;;
  esac
}

android_abi_for_target() {
  case "$(arch_oci)" in
    amd64) printf '%s' "x86_64" ;;
    arm64) printf '%s' "arm64-v8a" ;;
    386) printf '%s' "x86" ;;
    riscv64) printf '%s' "riscv64" ;;
    *) printf '%s' "" ;;
  esac
}
