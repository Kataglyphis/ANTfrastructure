#!/usr/bin/env bash
set -euo pipefail

# An optional status output observes source failures without suppressing direct errexit.
_source_toolchain_first_available() {
  local -n _toolchain_source_result="$1"
  local script_dir="$2" leaf="$3" priority="${4:-core-first}" candidate source_status status_output="${5:-}"
  if [ -n "$status_output" ]; then
    local -n _toolchain_status_result="$status_output"
    _toolchain_status_result=0
  fi
  local candidates=()
  [ "$priority" = core-paths-only ] || candidates=("${script_dir}/${leaf}")
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
    source_status=$?
    if [ -n "$status_output" ]; then _toolchain_status_result="$source_status"; fi
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

# Expected exports require successful sourcing; file-only callers retain their historical normalization.
source_toolchain_required() {
  local script_dir="$1" leaf="$2" missing="${3:-return}" priority="${4:-core-first}" symbol="${5:-}" _toolchain_source_matched=0 _toolchain_status=0 failure=1
  _source_toolchain_first_available _toolchain_source_matched "$script_dir" "$leaf" "$priority" _toolchain_status
  if [ "$_toolchain_source_matched" -eq 0 ]; then
    printf 'ERROR: toolchain bootstrap requires %s\n' "$leaf" >&2
  elif [ -n "$symbol" ] && [ "$_toolchain_status" -ne 0 ]; then
    printf 'ERROR: toolchain bootstrap source %s failed with status %s\n' "$leaf" "$_toolchain_status" >&2
    failure="$_toolchain_status"
  elif [ -n "$symbol" ] && ! declare -F "$symbol" >/dev/null; then
    printf 'ERROR: toolchain bootstrap requires %s from %s\n' "$symbol" "$leaf" >&2
  else return 0; fi
  if [ "$missing" = exit ]; then exit "$failure"; fi
  return "$failure"
}

source_toolchain_elf_strip() {
  source_toolchain_required "$1" elf-strip.sh
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

# Supplied download helpers win; standalone callers use exactly the two historical core locations.
source_toolchain_downloads() {
  local caller="$1" _std_found
  if command -v download_file >/dev/null 2>&1; then return 0; fi
  _source_toolchain_first_available _std_found \
    "$(cd "$(dirname "$caller")" && pwd)" downloads.sh core-paths-only
  return 0
}
