#!/usr/bin/env bash
# shellcheck shell=bash

download_module_load() {
  local downloads_file

  command -v download_and_extract >/dev/null 2>&1 && return 0
  downloads_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/downloads.sh"
  [ -f "${downloads_file}" ] || return 0
  # shellcheck source=downloads.sh
  source "${downloads_file}"
}

download_verified_extract_xz() {
  local url="$1" sha256="$2" archive="$3" destination="$4"

  download_verified_file "${url}" "${sha256}" "${archive}" || return $?
  mkdir -p "${destination}" || return $?
  tar -xJf "${archive}" -C "${destination}" || return $?
  rm -f "${archive}"
}
