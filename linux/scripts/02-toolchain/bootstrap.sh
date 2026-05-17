#!/usr/bin/env bash

source_toolchain_common_or_fallback() {
  local script_dir="$1"
  local candidate

  for candidate in \
    "${script_dir}/common.sh" \
    "${script_dir}/../01-core/common.sh" \
    "/opt/scripts/core/common.sh"; do
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
