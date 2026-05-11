#!/usr/bin/env bash
set -euo pipefail

use_fast_mirror="${USE_FAST_UBUNTU_MIRROR:-false}"
mirror_url="${FAST_UBUNTU_MIRROR_URL:-https://archive.ubuntu.com/ubuntu/}"
rewrite_security="${FAST_UBUNTU_REWRITE_SECURITY:-false}"

case "${mirror_url}" in
  */) ;;
  *) mirror_url="${mirror_url}/" ;;
esac

case "${use_fast_mirror}" in
  1|true|TRUE|yes|YES) ;;
  *) exit 0 ;;
esac

escaped_mirror_url="$(printf '%s' "${mirror_url}" | sed 's/[&|]/\\&/g')"
archive_regex='https?://([A-Za-z0-9-]+\.)?archive\.ubuntu\.com/ubuntu/?'
security_regex='https?://security\.ubuntu\.com/ubuntu/?'
updated=0

sed_args=("-e" "s|${archive_regex}|${escaped_mirror_url}|g")
grep_regex="${archive_regex}"
mirror_scope="archive"

case "${rewrite_security}" in
  1|true|TRUE|yes|YES)
    sed_args+=("-e" "s|${security_regex}|${escaped_mirror_url}|g")
    grep_regex="${archive_regex}|${security_regex}"
    mirror_scope="archive/security"
    ;;
esac

for sources_file in /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list; do
  [ -f "${sources_file}" ] || continue

  if grep -Eq "${grep_regex}" "${sources_file}"; then
    sed -E -i "${sed_args[@]}" "${sources_file}"
    printf '[INFO] Switched Ubuntu %s mirror entries in %s to %s\n' "${mirror_scope}" "${sources_file}" "${mirror_url}"
    updated=1
  fi
done

if [ "${updated}" -eq 0 ]; then
  printf '[INFO] USE_FAST_UBUNTU_MIRROR=true but no archive.ubuntu.com or security.ubuntu.com entry was found\n'
fi
