#!/usr/bin/env bash
# downloads.sh - shared download and checksum helpers
[ -n "${_DOWNLOADS_SH_LOADED:-}" ] && return 0
_DOWNLOADS_SH_LOADED=1

# Fallback die() in case logging.sh is not sourced before this file.
if ! command -v die >/dev/null 2>&1; then
  die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
fi

# download_file <url> <dest> [retries=3] [connect_timeout] [max_time]; max_time is curl-only. DOWNLOAD_RETRY_DELAY defaults to 20 s: 2 s outwaited GitHub's 60 s HTTP 500 (2026-10-21).
download_file() {
  local url="$1"
  local dest="$2"
  local retries="${3:-3}"
  local connect_timeout="${4:-}"
  local max_time="${5:-}"
  local retry_delay="${DOWNLOAD_RETRY_DELAY:-20}"

  if command -v curl >/dev/null 2>&1; then
    local -a curl_opts=()
    [ -n "${connect_timeout}" ] && curl_opts+=(--connect-timeout "${connect_timeout}")
    [ -n "${max_time}" ] && curl_opts+=(--max-time "${max_time}")
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --retry "${retries}" --retry-delay "${retry_delay}" ${curl_opts[@]+"${curl_opts[@]}"} -o "$dest" "$url"
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

# Mirror config: KATAGLYPHIS_ASSET_MIRROR_FILE, else the RUN's asset_mirror secret, else the host's file. docs/shared-script-libraries.md#the-asset-mirror
download_mirror_config_file() {
  case "${KATAGLYPHIS_ASSET_MIRROR:-on}" in 0|off|false|no) return 1 ;; esac
  local f
  if [ -n "${KATAGLYPHIS_ASSET_MIRROR_FILE:-}" ]; then
    f="${KATAGLYPHIS_ASSET_MIRROR_FILE}"
    [ -r "${f}" ] || return 1
    printf '%s\n' "${f}"
    return 0
  fi
  for f in /run/secrets/asset_mirror "${XDG_CONFIG_HOME:-${HOME:-/root}/.config}/kataglyphis/asset-mirror.env"; do
    if [ -r "${f}" ]; then
      printf '%s\n' "${f}"
      return 0
    fi
  done
  return 1
}

download_mirror_value() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1
}

# <url>: the object's name under <sha256>/, the last path segment without query or fragment.
download_mirror_object_name() {
  local name="${1%%[?#]*}"
  name="${name##*/}"
  printf '%s\n' "${name:-asset}"
}

# <config-file> <curl args...>: curl, SigV4-signed when the file holds a key; the key reaches curl on stdin, never argv.
download_mirror_curl() {
  local file="$1" key secret region cfg=""
  shift
  local -a sign=()
  key="$(download_mirror_value "${file}" AWS_ACCESS_KEY_ID)"
  secret="$(download_mirror_value "${file}" AWS_SECRET_ACCESS_KEY)"
  region="$(download_mirror_value "${file}" AWS_REGION)"
  if [ -n "${key}" ] && [ -n "${secret}" ]; then
    case "${key}${secret}" in
      *[\"\\[:space:]]*)
        printf 'asset-mirror| the key in %s holds a quote, backslash or space -- not used\n' "${file}" >&2
        return 2 ;;
    esac
    sign=(--aws-sigv4 "aws:amz:${region:-garage}:s3")
    cfg="user = \"${key}:${secret}\""
  fi
  curl --proto '=http,https' -fsS --connect-timeout 3 \
    --speed-limit 1024 --speed-time 30 ${sign[@]+"${sign[@]}"} -K - "$@" <<<"${cfg}"
}

# <sha256> <url> <dest> [file|stream]: 0 when the mirror served <sha256>/<name> into <dest>; the caller still verifies it.
download_mirror_fetch() {
  local sha="$1" url="$2" dest="$3" mode="${4:-file}" file base name rc=0
  [[ "${sha}" =~ ^[0-9a-f]{64}$ ]] || return 1
  [ -z "${_DOWNLOAD_MIRROR_DOWN:-}" ] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  file="$(download_mirror_config_file)" || return 1
  base="$(download_mirror_value "${file}" ASSET_MIRROR_URL)"
  [ -n "${base}" ] || return 1
  name="$(download_mirror_object_name "${url}")"
  download_mirror_curl "${file}" -o "${dest}" "${base%/}/${sha}/${name}" || rc=$?
  [ "${rc}" -eq 0 ] && return 0
  rm -f "${dest}"
  case "${rc}" in
    # A dead mirror would otherwise cost every later download its connect timeout.
    6|7|28)
      _DOWNLOAD_MIRROR_DOWN=1
      printf 'asset-mirror| %s unreachable (curl %s) -- upstream for the rest of this shell\n' "${base}" "${rc}" >&2 ;;
    2) ;;
    *) printf 'asset-mirror| miss %s %s %s\n' "${sha}" "${url}" "${mode}" >&2 ;;
  esac
  return 1
}

# $4=stream hashes the decompressed bytes: GitHub may re-encode codeload gzip, the stream stays stable.
download_verified_file() {
  local url="$1"
  local expected_sha256="$2"
  local dest="$3"
  local hash_mode="${4:-file}"

  if download_mirror_fetch "${expected_sha256}" "${url}" "${dest}" "${hash_mode}"; then
    if download_verify_sha256 "${expected_sha256}" "${dest}" "${hash_mode}"; then
      printf 'asset-mirror| hit %s\n' "$(download_mirror_object_name "${url}")" >&2
      return 0
    fi
    printf 'asset-mirror| the mirrored %s failed its checksum -- fetching upstream\n' "$(download_mirror_object_name "${url}")" >&2
  fi
  download_file "$url" "$dest" || return 1
  download_verify_sha256 "${expected_sha256}" "${dest}" "${hash_mode}"
}

# <sha256> <file> [file|stream]: removes <file> and says why when it does not match.
download_verify_sha256() {
  local expected_sha256="$1" dest="$2" hash_mode="${3:-file}" checksum_output actual
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

download_optional_verified_file() {
  local url="$1" sha="$2" destination="$3" warning="$4"
  if [ -z "${sha}" ]; then
    echo "${warning}" >&2
    download_file "${url}" "${destination}" 3
    return $?
  fi
  download_verified_file "${url}" "${sha}" "${destination}"
}

# download_verified_cached <url> <sha256> <dest> [cache_dir]: a cached copy is re-verified before every reuse.
download_verified_cached() {
  local url="$1" sha="$2" dest="$3" cache_dir="${4:-}" cached=""
  if [ -n "${cache_dir}" ] && mkdir -p "${cache_dir}" 2>/dev/null; then
    cached="${cache_dir}/${sha}-${url##*/}"
    if [ -f "${cached}" ] && printf '%s  %s\n' "${sha}" "${cached}" | sha256sum -c - >/dev/null 2>&1; then
      cp "${cached}" "${dest}" || return 1
      printf 'cache hit: %s\n' "${url##*/}"
      return 0
    fi
    rm -f "${cached}"
  fi
  download_verified_file "${url}" "${sha}" "${dest}" || return 1
  [ -n "${cached}" ] || return 0
  # A temp name, then mv, so a concurrent build never reads a partial file.
  if ! { cp "${dest}" "${cached}.partial.$$" && mv -f "${cached}.partial.$$" "${cached}"; }; then
    rm -f "${cached}.partial.$$"
    printf 'WARNING: could not cache %s in %s\n' "${url##*/}" "${cache_dir}" >&2
  fi
  return 0
}

# download_verified_install <url> <sha256> <dest> [archive member]: <dest> appears by one rename, so a parallel caller never runs half a binary.
download_verified_install() {
  local url="$1" sha="$2" dest="$3" member="${4:-}" dir stage got rc=0
  dir="$(dirname "${dest}")"
  mkdir -p "${dir}" && stage="$(mktemp -d "${dir}/.stage.XXXXXX")" || return 1
  got="${stage}/${url##*/}"
  download_verified_file "${url}" "${sha}" "${got}" || rc=1
  if [ "${rc}" -eq 0 ] && [ -n "${member}" ]; then
    case "${url}" in
      *.zip) unzip -oq "${got}" "${member}" -d "${stage}" ;;
      *) tar -xf "${got}" -C "${stage}" "${member}" ;;
    esac || { printf 'Extracting %s from %s failed\n' "${member}" "${url##*/}" >&2; rc=1; }
    got="${stage}/${member}"
  fi
  # A parallel caller may have won the rename; on Windows its running .exe then refuses ours.
  if [ "${rc}" -eq 0 ]; then
    { chmod +x "${got}" && mv -f "${got}" "${dest}" 2>/dev/null; } || [ -x "${dest}" ] || rc=1
  fi
  rm -rf "${stage}"
  return "${rc}"
}

fetch_repository_ref_best_effort() {
  git -C "$1" fetch --depth 1 origin "$2" 2>/dev/null \
    || git -C "$1" fetch --depth 1 --tags 2>/dev/null || true
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
    fetch_repository_ref_best_effort "${dest_dir}" "${branch}"
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

# Explicit failures keep exact-commit staging safe even when a caller disables errexit.
clone_pinned_repository() {
  local url="$1" destination="$2" commit="$3" actual
  git clone --quiet --filter=blob:none --no-checkout "${url}" "${destination}" \
    || git clone --quiet --no-checkout "${url}" "${destination}" || return 1
  git -C "${destination}" checkout --quiet "${commit}" || return 1
  actual="$(git -C "${destination}" rev-parse HEAD)" || return 1
  if [ "${actual}" = "${commit}" ]; then return 0; fi
  return 1
}
