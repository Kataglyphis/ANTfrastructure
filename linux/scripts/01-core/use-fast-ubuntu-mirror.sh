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

# Apply a mirror rewrite to a sources file.  Returns 0 if the file was
# modified, 1 if the file is missing or nothing matched (not an error).
apply_mirror_rewrite() {
  local sources_file="$1"
  local regex="$2"
  local replacement_url="$3"
  local label="$4"
  local escaped_replacement_url

  [ -f "${sources_file}" ] || return 1
  grep -Eq "${regex}" "${sources_file}" || return 1

  escaped_replacement_url="$(printf '%s' "${replacement_url}" | sed 's/[&|]/\\&/g')"
  sed -E -i "s|${regex}|${escaped_replacement_url}|g" "${sources_file}"
  printf '[INFO] Switched Ubuntu %s mirror entries in %s to %s\n' "${label}" "${sources_file}" "${replacement_url}"
  return 0
}

main() {
  local use_fast_mirror="${USE_FAST_UBUNTU_MIRROR:-false}"
  local archive_mirror_url ports_mirror_url rewrite_security sources_file updated sources_root
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
    apply_mirror_rewrite "${sources_file}" "$(ubuntu_archive_regex)" "${archive_mirror_url}" archive && updated=1

    if ubuntu_mirror_is_truthy "${rewrite_security}"; then
      apply_mirror_rewrite "${sources_file}" "$(ubuntu_security_regex)" "${archive_mirror_url}" security && updated=1
    fi

    apply_mirror_rewrite "${sources_file}" "$(ubuntu_ports_regex)" "${ports_mirror_url}" ports && updated=1
  done

  if [ "${updated}" -eq 0 ]; then
    printf '[INFO] USE_FAST_UBUNTU_MIRROR=true but no Ubuntu archive, security, or ports mirror entry was found\n'
  fi
}

main "$@"
