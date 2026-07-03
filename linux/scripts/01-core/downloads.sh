#!/usr/bin/env bash
# downloads.sh - shared download and checksum helpers
[ -n "${_DOWNLOADS_SH_LOADED:-}" ] && return 0
_DOWNLOADS_SH_LOADED=1
#
# NOTE: download_file() calls die() which requires logging.sh to be sourced
# before this file.  When sourced through common.sh this is guaranteed;
# if sourcing independently, source logging.sh first.

# Fallback die() in case logging.sh is not sourced before this file.
if ! command -v die >/dev/null 2>&1; then
  die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
fi

# download_file <url> <dest> [retries] [connect_timeout] [max_time]
#   retries          number of retry attempts (default 3, the historical value)
#   connect_timeout  per-connection timeout in seconds (default: tool default)
#   max_time         hard cap on total transfer time in seconds (curl only;
#                    wget has no equivalent, so it is ignored there)
# With only <url> <dest> the invocation is flag-identical to the historical
# behaviour; the optional arguments exist so call sites migrated from bespoke
# wget/curl invocations can keep their exact retry/timeout characteristics.
download_file() {
  local url="$1"
  local dest="$2"
  local retries="${3:-3}"
  local connect_timeout="${4:-}"
  local max_time="${5:-}"

  if command -v curl >/dev/null 2>&1; then
    local -a curl_opts=()
    [ -n "${connect_timeout}" ] && curl_opts+=(--connect-timeout "${connect_timeout}")
    [ -n "${max_time}" ] && curl_opts+=(--max-time "${max_time}")
    curl --proto '=https' --tlsv1.2 -fsSL --retry "${retries}" --retry-delay 2 ${curl_opts[@]+"${curl_opts[@]}"} -o "$dest" "$url"
  elif command -v wget >/dev/null 2>&1; then
    local -a wget_opts=()
    [ -n "${connect_timeout}" ] && wget_opts+=(--timeout="${connect_timeout}")
    wget -q --tries="${retries}" ${wget_opts[@]+"${wget_opts[@]}"} -O "$dest" "$url"
  else
    die "Neither curl nor wget is available for downloads"
  fi
}

# download_and_extract <url> <dest_dir> [strip_components] [retries] [connect_timeout] [max_time]
# Fetch a tarball to a temp file and extract it into <dest_dir>
# (tar auto-detects gz/xz/bz2 compression). The temp file is always
# removed, including on download or extraction failure, so a partial
# download never leaks. Returns non-zero on failure; caller decides
# whether that is fatal.
download_and_extract() {
  local url="$1"
  local dest_dir="$2"
  local strip="${3:-0}"
  local retries="${4:-3}"
  local connect_timeout="${5:-}"
  local max_time="${6:-}"
  local tmp_tar

  mkdir -p "${dest_dir}" || { printf 'Failed to create %s\n' "${dest_dir}" >&2; return 1; }
  tmp_tar="$(mktemp "${TMPDIR:-/tmp}/download-extract-XXXXXX")" || { printf 'mktemp failed for %s\n' "${url}" >&2; return 1; }

  if ! download_file "${url}" "${tmp_tar}" "${retries}" "${connect_timeout}" "${max_time}"; then
    rm -f "${tmp_tar}"
    printf 'Download failed: %s\n' "${url}" >&2
    return 1
  fi
  if ! tar -xf "${tmp_tar}" -C "${dest_dir}" --strip-components="${strip}"; then
    rm -f "${tmp_tar}"
    printf 'Extraction failed for %s (into %s)\n' "${url}" "${dest_dir}" >&2
    return 1
  fi
  rm -f "${tmp_tar}"
}

download_verified_file() {
  local url="$1"
  local expected_sha256="$2"
  local dest="$3"
  local checksum_output

  download_file "$url" "$dest"
  checksum_output="$(printf '%s  %s\n' "$expected_sha256" "$dest" | sha256sum -c - 2>&1)" || {
    printf 'Checksum verification FAILED for %s: %s\n' "${dest}" "${checksum_output}" >&2
    rm -f "$dest"
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
    git -C "${dest_dir}" fetch --depth 1 origin "${branch}" 2>/dev/null || git -C "${dest_dir}" fetch --depth 1 --tags 2>/dev/null || true
    if [ -n "${branch}" ]; then
      git -C "${dest_dir}" checkout "${branch}" 2>/dev/null || true
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
