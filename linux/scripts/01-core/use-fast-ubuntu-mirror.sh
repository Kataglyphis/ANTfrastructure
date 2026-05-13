#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
if [ -f "${SCRIPT_DIR}/ubuntu-mirror.sh" ]; then
  source "${SCRIPT_DIR}/ubuntu-mirror.sh"
elif [ -f "/opt/scripts/core/ubuntu-mirror.sh" ]; then
  source "/opt/scripts/core/ubuntu-mirror.sh"
else
  # Some Dockerfiles mount only this script during early bootstrap steps.
  # Keep the mirror helpers inlined here so those steps do not depend on
  # sibling files already existing inside the image.
  ubuntu_mirror_is_truthy() {
    case "${1:-false}" in
      1|true|TRUE|yes|YES) return 0 ;;
      *) return 1 ;;
    esac
  }

  ubuntu_mirror_normalize_url() {
    local url="${1:-}"

    case "${url}" in
      */) printf '%s' "${url}" ;;
      *) printf '%s/' "${url}" ;;
    esac
  }

  ubuntu_archive_regex() {
    printf '%s' 'https?://([A-Za-z0-9-]+\.)?archive\.ubuntu\.com/ubuntu/?'
  }

  ubuntu_security_regex() {
    printf '%s' 'https?://security\.ubuntu\.com/ubuntu/?'
  }

  ubuntu_ports_regex() {
    printf '%s' 'https?://ports\.ubuntu\.com/ubuntu-ports/?'
  }

  ubuntu_default_archive_mirror_url() {
    printf '%s' 'https://archive.ubuntu.com/ubuntu/'
  }

  ubuntu_default_ports_mirror_url() {
    printf '%s' 'http://ports.ubuntu.com/ubuntu-ports/'
  }

  ubuntu_archive_mirror_is_official() {
    local normalized_url

    normalized_url="$(ubuntu_mirror_normalize_url "${1:-$(ubuntu_default_archive_mirror_url)}")"
    [[ "${normalized_url}" =~ ^https?://([A-Za-z0-9-]+\.)?archive\.ubuntu\.com/ubuntu/$ ]]
  }

  ubuntu_ports_mirror_from_archive() {
    local archive_url

    archive_url="$(ubuntu_mirror_normalize_url "${1:-$(ubuntu_default_archive_mirror_url)}")"
    if ubuntu_archive_mirror_is_official "${archive_url}"; then
      ubuntu_default_ports_mirror_url
      return 0
    fi

    case "${archive_url}" in
      */ubuntu/)
        printf '%s' "${archive_url%/ubuntu/}/ubuntu-ports/"
        ;;
      *)
        printf '%s' "${archive_url}"
        ;;
    esac
  }

  ubuntu_effective_ports_mirror_url() {
    local archive_url="${1:-$(ubuntu_default_archive_mirror_url)}"
    local explicit_ports_url="${2:-}"

    if [ -n "${explicit_ports_url}" ]; then
      ubuntu_mirror_normalize_url "${explicit_ports_url}"
      return 0
    fi

    ubuntu_ports_mirror_from_archive "${archive_url}"
  }
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
