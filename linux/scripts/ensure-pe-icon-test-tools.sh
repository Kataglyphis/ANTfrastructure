#!/usr/bin/env bash
# Installs missing Ubuntu test tools only when explicitly requested; it does not prepare build images.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/lib/pe-icon-tools.sh
source "${SCRIPT_DIR}/lib/pe-icon-tools.sh"

pe_icon_missing_packages() {
  if ! pe_icon_find_tool llvm-rc >/dev/null || ! pe_icon_find_tool llvm-readobj >/dev/null; then echo llvm-22; fi
  if ! pe_icon_find_tool lld-link >/dev/null || ! pe_icon_find_tool ld.lld >/dev/null; then echo lld-22; fi
  if ! pe_icon_find_clang >/dev/null; then echo clang-22; fi
  if ! command -v rustc >/dev/null || ! rustc --edition=2024 --version >/dev/null 2>&1; then echo rustc; fi
  if ! command -v cargo >/dev/null; then echo cargo; fi
  if ! command -v ninja >/dev/null; then echo ninja-build; fi
  if ! command -v cmake >/dev/null; then echo cmake; fi
  if ! command -v python3 >/dev/null; then echo python3; fi
}

pe_icon_as_root() {
  local uid
  uid="$(id -u)" || return $?
  if [ "${uid}" -eq 0 ]; then "$@"; else sudo -n "$@"; fi
}

pe_icon_ensure_test_tools() {
  local mode="${1:-}"
  if [ -n "${mode}" ] && [ "${mode}" != --install-missing ]; then
    echo "usage: $0 [--install-missing]" >&2; return 2
  fi
  if ! command -v pwsh >/dev/null; then echo "PE icon tests require PowerShell 7 (pwsh)." >&2; return 1; fi
  local -a missing=()
  mapfile -t missing < <(pe_icon_missing_packages)
  if [ "${#missing[@]}" -eq 0 ]; then echo "PE icon test tools are available."; return 0; fi
  if [ "${mode}" != --install-missing ]; then
    echo "Missing PE icon test packages: ${missing[*]} (rerun with --install-missing on Ubuntu)." >&2; return 1
  fi
  if ! command -v apt-get >/dev/null || { [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null; }; then
    echo "Installing PE icon test tools needs apt-get and root or sudo." >&2; return 1
  fi
  pe_icon_as_root apt-get update || return $?
  pe_icon_as_root apt-get install -y --no-install-recommends "${missing[@]}" || return $?
  mapfile -t missing < <(pe_icon_missing_packages)
  if [ "${#missing[@]}" -gt 0 ]; then echo "PE icon tools remain unavailable: ${missing[*]}" >&2; return 1; fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then pe_icon_ensure_test_tools "$@"; fi
