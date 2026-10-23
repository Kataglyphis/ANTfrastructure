#!/usr/bin/env bash
set -euo pipefail

_source_toolchain_first_available() {
  local -n _toolchain_source_result="$1"
  local script_dir="$2" leaf="$3" priority="${4:-core-first}" candidate
  local candidates=("${script_dir}/${leaf}")
  if [ "$priority" = mounted-first ]; then
    candidates+=("/opt/scripts/core/${leaf}" "${script_dir}/../01-core/${leaf}")
  else
    candidates+=("${script_dir}/../01-core/${leaf}" "/opt/scripts/core/${leaf}")
  fi
  _toolchain_source_result=0
  for candidate in "${candidates[@]}"; do
    [ -f "$candidate" ] || continue
    # shellcheck disable=SC1090
    source "$candidate"
    _toolchain_source_result=1
    return 0
  done
  return 0
}

source_toolchain_common_or_fallback() {
  local script_dir="$1" _toolchain_source_matched=0

  _source_toolchain_first_available _toolchain_source_matched "$script_dir" common.sh mounted-first
  [ "$_toolchain_source_matched" -eq 0 ] || return 0

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
  local script_dir="$1" _toolchain_source_matched=0

  _source_toolchain_first_available _toolchain_source_matched "$script_dir" build-helpers.sh
  [ "$_toolchain_source_matched" -eq 0 ] || return 0

  source_toolchain_elf_strip "${script_dir}"
}

source_toolchain_elf_strip() {
  local script_dir="$1" _toolchain_source_matched=0
  _source_toolchain_first_available _toolchain_source_matched "$script_dir" elf-strip.sh
  [ "$_toolchain_source_matched" -eq 0 ] || return 0
  printf 'ERROR: toolchain bootstrap requires elf-strip.sh\n' >&2
  return 1
}

toolchain_cache_usage() {
  local description_column="$1"
  printf '  %-*s %s\n' "$((description_column - 3))" --compiler-cache 'Enable the compiler cache (sccache first, ccache fallback)'
  printf '  %-*s %s\n' "$((description_column - 3))" --ccache 'DEPRECATED alias for --compiler-cache'
}

toolchain_unknown_option() {
  warn "Unknown option: $1"
  usage >&2
  exit 1
}
