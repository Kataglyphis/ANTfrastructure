#!/usr/bin/env bash

# downloads.sh - shared download and checksum helpers

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

  download_file "$url" "$dest"
  printf '%s  %s\n' "$expected_sha256" "$dest" | sha256sum -c - >/dev/null
}
