#!/usr/bin/env bash

# ubuntu-mirror.sh - shared helpers for Ubuntu archive/security/ports mirrors

[ -n "${_UBUNTU_MIRROR_SH_LOADED:-}" ] && return 0
_UBUNTU_MIRROR_SH_LOADED=1

_UBUNTU_MIRROR_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defensive: guarantee the canonical is_truthy() (platform.sh) is available even
# when this file is sourced standalone (use-fast-ubuntu-mirror.sh sources ONLY
# ubuntu-mirror.sh). platform.sh has its own load guard, so this is a no-op when
# it is already loaded.
# shellcheck disable=SC1090,SC1091
[ -n "${_PLATFORM_SH_LOADED:-}" ] || \
  { [ -f "${_UBUNTU_MIRROR_SH_DIR}/platform.sh" ] && source "${_UBUNTU_MIRROR_SH_DIR}/platform.sh"; }

# Thin alias delegating to the canonical is_truthy() (platform.sh). Kept for the
# existing callers (base-image.sh, cross-env.sh, use-fast-ubuntu-mirror.sh).
ubuntu_mirror_is_truthy() {
  is_truthy "${1:-false}"
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

init_mirror_defaults() {
  : "${USE_FAST_UBUNTU_MIRROR:=false}"
  : "${FAST_UBUNTU_MIRROR_URL:=${FAST_UBUNTU_MIRROR_URL_DEFAULT:-https://archive.ubuntu.com/ubuntu/}}"
  : "${FAST_UBUNTU_PORTS_MIRROR_URL:=}"
}
