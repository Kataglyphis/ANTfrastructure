#!/usr/bin/env bash
set -euo pipefail

source_toolchain_common_or_fallback() {
  local script_dir="$1"
  local candidate

  for candidate in \
    "${script_dir}/common.sh" \
    "/opt/scripts/core/common.sh" \
    "${script_dir}/../01-core/common.sh"; do
    [ -f "${candidate}" ] || continue
    # shellcheck disable=SC1090
    source "${candidate}"
    return 0
  done

  info() { printf '[INFO] %s\n' "$*"; }
  warn() { printf '[WARN] %s\n' "$*" >&2; }
  err()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
  die()  { err "$@"; }
  require_sudo() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
      command -v sudo >/dev/null 2>&1 || die "This script requires sudo or root."
      SUDO="sudo"
    else
      SUDO=""
    fi
  }
  apt_install() {
    ${SUDO:-} apt-get update -qq
    ${SUDO:-} apt-get install -y --no-install-recommends "$@"
  }
  detect_system() { :; }
}

# common.sh does not pull in build-helpers.sh, so the from-source builders load it here, with a minimal fallback.
source_toolchain_build_helpers_or_fallback() {
  local script_dir="$1"
  local candidate

  for candidate in \
    "${script_dir}/build-helpers.sh" \
    "${script_dir}/../01-core/build-helpers.sh" \
    "/opt/scripts/core/build-helpers.sh"; do
    [ -f "${candidate}" ] || continue
    # shellcheck disable=SC1090
    source "${candidate}"
    return 0
  done

  source_toolchain_elf_strip "${script_dir}"
}

source_toolchain_elf_strip() {
  local script_dir="$1" candidate
  for candidate in \
    "${script_dir}/elf-strip.sh" \
    "${script_dir}/../01-core/elf-strip.sh" \
    "/opt/scripts/core/elf-strip.sh"; do
    [ -f "${candidate}" ] || continue
    # shellcheck disable=SC1090
    source "${candidate}"
    return 0
  done
  printf 'ERROR: toolchain bootstrap requires elf-strip.sh\n' >&2
  return 1
}
