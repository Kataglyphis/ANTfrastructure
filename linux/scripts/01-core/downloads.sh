#!/usr/bin/env bash
# downloads.sh - shared download and checksum helpers
[ -n "${_DOWNLOADS_SH_LOADED:-}" ] && return 0
_DOWNLOADS_SH_LOADED=1

# Fallback die() in case logging.sh is not sourced before this file.
if ! command -v die >/dev/null 2>&1; then
  die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
fi

# download_file <url> <dest> [retries=3] [connect_timeout] [max_time]; max_time is curl-only (wget has none).
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
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --retry "${retries}" --retry-delay 2 ${curl_opts[@]+"${curl_opts[@]}"} -o "$dest" "$url"
  elif command -v wget >/dev/null 2>&1; then
    local -a wget_opts=()
    [ -n "${connect_timeout}" ] && wget_opts+=(--timeout="${connect_timeout}")
    # Same TLS floor as the curl branch, which additionally refuses https->http redirects.
    wget -q --https-only --secure-protocol=TLSv1_2 --tries="${retries}" ${wget_opts[@]+"${wget_opts[@]}"} -O "$dest" "$url"
  else
    die "Neither curl nor wget is available for downloads"
  fi
}

# download_and_extract <url> <dest_dir> [strip] [retries] [connect_timeout] [max_time]; the caller decides if failure is fatal.
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

# $4=stream hashes the decompressed bytes: GitHub may re-encode codeload gzip, the stream stays stable.
download_verified_file() {
  local url="$1"
  local expected_sha256="$2"
  local dest="$3"
  local hash_mode="${4:-file}"
  local checksum_output actual

  download_file "$url" "$dest"
  if [ "${hash_mode}" = "stream" ]; then
    actual="$(gunzip -c "$dest" 2>/dev/null | sha256sum | awk '{print $1}')"
    [ "${actual}" = "${expected_sha256}" ] || {
      printf 'Stream checksum verification FAILED for %s: got %s, expected %s\n' \
        "${dest}" "${actual:-<none>}" "${expected_sha256}" >&2
      rm -f "$dest"
      return 1
    }
    return 0
  fi
  checksum_output="$(printf '%s  %s\n' "$expected_sha256" "$dest" | sha256sum -c - 2>&1)" || {
    printf 'Checksum verification FAILED for %s: %s\n' "${dest}" "${checksum_output}" >&2
    rm -f "$dest"
    return 1
  }
}

clone_or_update_repo() {
  local repo_url="$1"
  local dest_dir="$2"
  local branch="${3:-}"

  # A 40-hex "branch" is a commit pin; --branch accepts only refs, so fetch that exact commit.
  if [[ "${branch}" =~ ^[0-9a-f]{40}$ ]]; then
    rm -rf "${dest_dir}"
    mkdir -p "${dest_dir}"
    git -C "${dest_dir}" init -q
    git -C "${dest_dir}" remote add origin "${repo_url}"
    git -C "${dest_dir}" fetch --depth 1 origin "${branch}"
    git -C "${dest_dir}" checkout -q FETCH_HEAD
    return 0
  fi

  if [ -d "${dest_dir}/.git" ]; then
    git -C "${dest_dir}" fetch --depth 1 origin "${branch}" 2>/dev/null || git -C "${dest_dir}" fetch --depth 1 --tags 2>/dev/null || true
    if [ -n "${branch}" ]; then
      git -C "${dest_dir}" checkout "${branch}" 2>/dev/null || true
      # The fetch/checkout above tolerate failure on purpose, so say loudly when the ref did not land.
      local _want _have _have_desc
      _want="$(git -C "${dest_dir}" rev-parse --verify --quiet "${branch}^{commit}" 2>/dev/null || true)"
      _have="$(git -C "${dest_dir}" rev-parse --verify --quiet HEAD 2>/dev/null || true)"
      # A stale checkout only warns; no HEAD at all means a crashed clone with nothing to build from.
      if [ -z "${_have}" ]; then
        printf 'ERROR: no usable HEAD in %s (requested ref: %s); previous clone/fetch failed. Delete the directory and retry.\n' \
          "${dest_dir}" "${branch}" >&2
        return 1
      fi
      if [ -z "${_want}" ] || [ "${_want}" != "${_have}" ]; then
        _have_desc="$(git -C "${dest_dir}" describe --tags --always 2>/dev/null || echo '?')"
        {
          echo "=================================================================="
          echo "WARNING: STALE CHECKOUT in ${dest_dir}"
          echo "  requested ref: ${branch} (${_want:-not resolvable locally; fetch failed?})"
          echo "  actual HEAD:   ${_have:-<none>} (${_have_desc})"
          echo "  Continuing on purpose: the build will use the ACTUAL HEAD above,"
          echo "  which is NOT the requested ref. Delete ${dest_dir} to force a"
          echo "  fresh clone if this is not intended."
          echo "=================================================================="
        } >&2
      fi
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
