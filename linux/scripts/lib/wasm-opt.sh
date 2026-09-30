#!/usr/bin/env bash
# Sourced (no shell options): a pinned, SHA-verified binaryen, since distro packages lag; pin shared with PowerShell via versions.env.

[ -n "${_WASM_OPT_SH_LOADED:-}" ] && return 0
_WASM_OPT_SH_LOADED=1

_WASM_OPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_WASM_OPT_CORE_DIR="${_WASM_OPT_LIB_DIR}/../01-core"
# shellcheck source=./log-bootstrap.sh
source "${_WASM_OPT_LIB_DIR}/log-bootstrap.sh"

# Features wgpu/naga codegen emits that wasm-opt's validator rejects by default; --all-features is the fallback.
WASM_OPT_FEATURE_FLAGS=(
  --enable-bulk-memory-opt
  --enable-nontrapping-float-to-int
  --enable-simd
  --enable-sign-ext
  --enable-reference-types
  --enable-mutable-globals
  --enable-multivalue
)

# The environment wins, which is how a caller pins another release without editing versions.env.
wasm_opt_load_pin() {
  local versions_file="${1:-${_WASM_OPT_CORE_DIR}/versions.env}"

  if [[ -f "${_WASM_OPT_CORE_DIR}/load-versions-env.sh" ]]; then
    # shellcheck source=../01-core/load-versions-env.sh
    source "${_WASM_OPT_CORE_DIR}/load-versions-env.sh"
    load_versions_env "${versions_file}"
    return 0
  fi

  # Read only the keys we need: versions.env is inert data and must never be sourced.
  local line name
  [[ -f "${versions_file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      BINARYEN_*=*) ;;
      *) continue ;;
    esac
    name="${line%%=*}"
    if [[ -z "${!name:-}" ]]; then export "${name}=${line#*=}"; fi
  done < "${versions_file}"
}

# [version]; e.g. binaryen-version_131-x86_64-linux.tar.gz.
wasm_opt_asset_name() {
  local version="${1:-${BINARYEN_VERSION:-}}"
  local machine
  machine="$(uname -m)"
  case "${machine}" in
    x86_64|amd64) machine="x86_64" ;;
    aarch64|arm64) machine="aarch64" ;;
    *) err "No binaryen release asset for machine '${machine}'." ;;
  esac
  printf 'binaryen-%s-%s-linux.tar.gz\n' "${version}" "${machine}"
}

# An arch without a pinned checksum is a hard error, never an unverified download.
wasm_opt_expected_sha() {
  local machine
  machine="$(uname -m)"
  case "${machine}" in
    x86_64|amd64) printf '%s\n' "${BINARYEN_LINUX_X86_64_SHA256:-}" ;;
    aarch64|arm64) printf '%s\n' "${BINARYEN_LINUX_AARCH64_SHA256:-}" ;;
    *) printf '\n' ;;
  esac
}

# A version-keyed cache (WASM_OPT_CACHE_DIR), so reruns reuse the download and a bump never reuses a stale binary.
wasm_opt_ensure() {
  if command -v wasm-opt >/dev/null 2>&1; then
    return 0
  fi

  wasm_opt_load_pin
  [[ -n "${BINARYEN_VERSION:-}" ]] || err "BINARYEN_VERSION is not set (versions.env not found?)."

  local asset expected_sha cache_root install_dir
  asset="$(wasm_opt_asset_name)" || return 1
  expected_sha="$(wasm_opt_expected_sha)"
  [[ -n "${expected_sha}" ]] || err "No pinned binaryen SHA256 for ${asset}; add one to versions.env."

  cache_root="${WASM_OPT_CACHE_DIR:-${TMPDIR:-/tmp}}"
  install_dir="${cache_root}/binaryen-${BINARYEN_VERSION}"

  if [[ ! -x "${install_dir}/bin/wasm-opt" ]]; then
    info "wasm-opt not on PATH; fetching pinned binaryen ${BINARYEN_VERSION}"
    # SHA-verified download comes from ANTfrastructure 01-core (download_verified_file).
    if ! declare -F download_verified_file >/dev/null 2>&1; then
      # shellcheck source=../01-core/downloads.sh
      source "${_WASM_OPT_CORE_DIR}/downloads.sh" 2>/dev/null \
        || err "ANTfrastructure downloads.sh not available for verified binaryen fetch"
    fi

    mkdir -p "${cache_root}" || err "Cannot create binaryen cache directory ${cache_root}"
    local tmp_dir
    tmp_dir="$(mktemp -d)" || err "mktemp -d failed"
    # Stop here: tar would only report "cannot open" and bury a failed download or checksum.
    if ! download_verified_file \
      "https://github.com/WebAssembly/binaryen/releases/download/${BINARYEN_VERSION}/${asset}" \
      "${expected_sha}" \
      "${tmp_dir}/${asset}"; then
      rm -rf "${tmp_dir}"
      err "Verified download of ${asset} failed (checksum mismatch or network error)."
    fi
    # The tarball's top directory is binaryen-${BINARYEN_VERSION}, i.e. exactly ${install_dir}.
    tar -xzf "${tmp_dir}/${asset}" -C "${cache_root}" || { rm -rf "${tmp_dir}"; err "Extracting ${asset} failed"; }
    rm -rf "${tmp_dir}"
  else
    info "Reusing cached binaryen ${BINARYEN_VERSION} from ${install_dir}"
  fi

  [[ -x "${install_dir}/bin/wasm-opt" ]] || err "wasm-opt missing in ${install_dir}/bin after bootstrap."
  export PATH="${install_dir}/bin:${PATH}"
}

# <input> <output> [level]; retries once with --all-features for a feature newer than the list.
wasm_opt_optimize() {
  local input="${1:?input wasm required}"
  local output="${2:?output wasm required}"
  local level="${3:--Oz}"

  wasm_opt_ensure

  if ! wasm-opt "${level}" "${WASM_OPT_FEATURE_FLAGS[@]}" "${input}" -o "${output}"; then
    warn "wasm-opt with explicit feature flags failed; retrying with --all-features"
    wasm-opt "${level}" --all-features "${input}" -o "${output}" \
      || err "wasm-opt failed for ${input}"
  fi
}
