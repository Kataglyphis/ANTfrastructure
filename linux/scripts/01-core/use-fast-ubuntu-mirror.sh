#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
if [ -f "${SCRIPT_DIR}/ubuntu-mirror.sh" ]; then
  source "${SCRIPT_DIR}/ubuntu-mirror.sh"
elif [ -f "/opt/scripts/core/ubuntu-mirror.sh" ]; then
  source "/opt/scripts/core/ubuntu-mirror.sh"
else
  printf '[ERROR] use-fast-ubuntu-mirror.sh: cannot find ubuntu-mirror.sh\n' >&2
  exit 1
fi

rewrite_mirror_entries() {
  local sources_file="$1"
  local regex="$2"
  local replacement_url="$3"
  local label="$4"
  local escaped_replacement_url

  [ -f "${sources_file}" ] || return 0
  if ! grep -Eq "${regex}" "${sources_file}"; then
    return 0
  fi

  escaped_replacement_url="$(printf '%s' "${replacement_url}" | sed 's/[&|]/\\&/g')"
  sed -E -i "s|${regex}|${escaped_replacement_url}|g" "${sources_file}"
  printf '[INFO] Switched Ubuntu %s mirror entries in %s to %s\n' "${label}" "${sources_file}" "${replacement_url}"
  return 10
}

run_rewrite_step() {
  local sources_file="$1"
  local regex="$2"
  local replacement_url="$3"
  local label="$4"
  local status=0

  set +e
  rewrite_mirror_entries "${sources_file}" "${regex}" "${replacement_url}" "${label}"
  status=$?
  set -e

  if [ "${status}" -eq 10 ]; then
    return 10
  fi

  return "${status}"
}

main() {
  local use_fast_mirror="${USE_FAST_UBUNTU_MIRROR:-false}"
  local archive_mirror_url ports_mirror_url rewrite_security sources_file updated status sources_root
  local -a source_files=()

  if ! ubuntu_mirror_is_truthy "${use_fast_mirror}"; then
    exit 0
  fi

  archive_mirror_url="$(ubuntu_mirror_normalize_url "${FAST_UBUNTU_MIRROR_URL:-$(ubuntu_default_archive_mirror_url)}")"
  ports_mirror_url="$(ubuntu_effective_ports_mirror_url "${archive_mirror_url}" "${FAST_UBUNTU_PORTS_MIRROR_URL:-}")"
  rewrite_security="${FAST_UBUNTU_REWRITE_SECURITY:-false}"
  sources_root="${UBUNTU_SOURCES_ROOT:-/}"
  updated=0

  shopt -s nullglob
  source_files=(
    "${sources_root%/}/etc/apt/sources.list"
    "${sources_root%/}/etc/apt/sources.list.d/"*.list
    "${sources_root%/}/etc/apt/sources.list.d/"*.sources
  )
  shopt -u nullglob

  for sources_file in "${source_files[@]}"; do
    run_rewrite_step "${sources_file}" "$(ubuntu_archive_regex)" "${archive_mirror_url}" archive || status=$?
    if [ "${status:-0}" -eq 10 ]; then
      updated=1
    elif [ "${status:-0}" -ne 0 ]; then
      exit "${status}"
    fi
    status=0

    if ubuntu_mirror_is_truthy "${rewrite_security}"; then
      run_rewrite_step "${sources_file}" "$(ubuntu_security_regex)" "${archive_mirror_url}" security || status=$?
      if [ "${status:-0}" -eq 10 ]; then
        updated=1
      elif [ "${status:-0}" -ne 0 ]; then
        exit "${status}"
      fi
      status=0
    fi

    run_rewrite_step "${sources_file}" "$(ubuntu_ports_regex)" "${ports_mirror_url}" ports || status=$?
    if [ "${status:-0}" -eq 10 ]; then
      updated=1
    elif [ "${status:-0}" -ne 0 ]; then
      exit "${status}"
    fi
    status=0
  done

  if [ "${updated}" -eq 0 ]; then
    printf '[INFO] USE_FAST_UBUNTU_MIRROR=true but no Ubuntu archive, security, or ports mirror entry was found\n'
  fi
}

main "$@"
