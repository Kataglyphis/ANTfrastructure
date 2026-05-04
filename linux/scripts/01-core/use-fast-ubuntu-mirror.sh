#!/usr/bin/env bash
set -euo pipefail

use_fast_mirror="${USE_FAST_UBUNTU_MIRROR:-false}"
mirror_url="${FAST_UBUNTU_MIRROR_URL:-http://de.archive.ubuntu.com/ubuntu/}"

case "${mirror_url}" in
  */) ;;
  *) mirror_url="${mirror_url}/" ;;
esac

case "${use_fast_mirror}" in
  1|true|TRUE|yes|YES) ;;
  *) exit 0 ;;
esac

escaped_mirror_url="$(printf '%s' "${mirror_url}" | sed 's/[&|]/\\&/g')"
updated=0

for sources_file in /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list; do
  [ -f "${sources_file}" ] || continue

  if grep -Eq 'https?://(archive|security)\.ubuntu\.com/ubuntu/?' "${sources_file}"; then
    sed -E -i \
      -e "s|https?://archive\\.ubuntu\\.com/ubuntu/?|${escaped_mirror_url}|g" \
      -e "s|https?://security\\.ubuntu\\.com/ubuntu/?|${escaped_mirror_url}|g" \
      "${sources_file}"
    printf '[INFO] Switched Ubuntu archive/security mirrors in %s to %s\n' "${sources_file}" "${mirror_url}"
    updated=1
  fi
done

if [ "${updated}" -eq 0 ]; then
  printf '[INFO] USE_FAST_UBUNTU_MIRROR=true but no archive.ubuntu.com or security.ubuntu.com entry was found\n'
fi
