#!/usr/bin/env bash

# downloads.sh - shared download and checksum helpers
#
# NOTE: download_file() calls die() which requires logging.sh to be sourced
# before this file.  When sourced through common.sh this is guaranteed;
# if sourcing independently, source logging.sh first.

download_file() {
  local url="$1"
  local dest="$2"

  if command -v curl >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --tries=3 -O "$dest" "$url"
  else
    die "Neither curl nor wget is available for downloads"
  fi
}

download_verified_file() {
  local url="$1"
  local expected_sha256="$2"
  local dest="$3"
  local checksum_output

  download_file "$url" "$dest"
  checksum_output="$(printf '%s  %s\n' "$expected_sha256" "$dest" | sha256sum -c - 2>&1)" || {
    printf 'Checksum verification FAILED for %s: %s\n' "${dest}" "${checksum_output}" >&2
    return 1
  }
}
