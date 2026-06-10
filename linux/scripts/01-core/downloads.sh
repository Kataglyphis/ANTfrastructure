#!/usr/bin/env bash

# downloads.sh - shared download and checksum helpers
#
# NOTE: download_file() calls die() which requires logging.sh to be sourced
# before this file.  When sourced through common.sh this is guaranteed;
# if sourcing independently, source logging.sh first.

# Fallback die() in case logging.sh is not sourced before this file.
if ! command -v die >/dev/null 2>&1; then
  die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
fi

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

# Clone or update a git repository. Uses shallow clone (--depth 1) to
# minimize bandwidth. If the repo already exists, does a git fetch in-place.
clone_or_update_repo() {
  local repo_url="$1"
  local dest_dir="$2"
  local branch="${3:-}"

  if [ -d "${dest_dir}/.git" ]; then
    cd "${dest_dir}"
    git fetch --depth 1 origin "${branch}" 2>/dev/null || git fetch --depth 1 --tags 2>/dev/null || true
    if [ -n "${branch}" ]; then
      git checkout "${branch}" 2>/dev/null || true
    fi
    return 0
  fi

  rm -rf "${dest_dir}"
  if [ -n "${branch}" ]; then
    git clone --depth 1 --branch "${branch}" "${repo_url}" "${dest_dir}"
  else
    git clone --depth 1 "${repo_url}" "${dest_dir}"
  fi
}
