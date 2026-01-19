#!/usr/bin/env bash
# platform.sh - small, side-effect-free platform helpers

_platform_raw_arch() {
  local raw="${TARGETARCH:-${TARGET_ARCH:-}}"
  if [ -z "${raw}" ]; then
    raw="$(uname -m 2>/dev/null || echo unknown)"
  fi
  printf '%s' "${raw}"
}

arch_oci() {
  # Returns OCI/Docker style arch names: amd64, arm64, riscv64, 386, ...
  local raw
  raw="$(_platform_raw_arch)"

  case "${raw}" in
    amd64|x86_64) printf '%s' "amd64" ;;
    arm64|aarch64) printf '%s' "arm64" ;;
    i386|i486|i586|i686|386) printf '%s' "386" ;;
    riscv64) printf '%s' "riscv64" ;;
    *) printf '%s' "${raw}" ;;
  esac
}

is_amd64_arch() {
  [ "$(arch_oci)" = "amd64" ]
}

deb_multiarch_triplet() {
  # Prefer the system-reported triplet when available.
  if command -v dpkg-architecture >/dev/null 2>&1; then
    local t
    t="$(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true)"
    if [ -n "${t}" ]; then
      printf '%s' "${t}"
      return 0
    fi
  fi

  # Fallback mapping.
  case "$(arch_oci)" in
    amd64) printf '%s' "x86_64-linux-gnu" ;;
    arm64) printf '%s' "aarch64-linux-gnu" ;;
    386) printf '%s' "i386-linux-gnu" ;;
    riscv64) printf '%s' "riscv64-linux-gnu" ;;
    *) printf '%s' "" ;;
  esac
}
