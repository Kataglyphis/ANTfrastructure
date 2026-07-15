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

# Load 01-core/build-helpers.sh (parallel ELF strip helper etc.). It is not
# pulled in by common.sh, so the from-source builders source it explicitly.
# Falls back to a minimal strip_elf_tree when 01-core is unavailable, matching
# the source-or-fallback idiom used by source_toolchain_common_or_fallback.
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

  strip_elf_tree() {
    local dir="$1" jobs="${2:-$(nproc)}" strip_bin="${3:-strip}"
    [ -n "${dir}" ] || return 0
    [ -d "${dir}" ] || return 0
    ${SUDO:-} find "${dir}" -type f -exec file {} + 2>/dev/null \
      | awk -F': *' '/ELF/{print $1}' \
      | xargs -r -P"${jobs}" "${strip_bin}" --strip-all 2>/dev/null || true
  }
}
