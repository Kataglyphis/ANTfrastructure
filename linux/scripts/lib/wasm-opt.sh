#!/usr/bin/env bash
# wasm-opt.sh - binaryen/wasm-opt bootstrap and optimisation helper.
#
# Two things every "check/shrink the wasm bundle" script needs and nothing
# project-specific:
#   1. a wasm-opt binary - not installed in most CI images and not worth a
#      distro package (they lag badly), so a pinned, SHA-verified binaryen
#      release is fetched on demand and put on PATH
#   2. the wasm feature flags that release has to be told about, because
#      wgpu/naga-style toolchains emit instructions wasm-opt's validator
#      rejects by default
#
# The version and the per-platform checksums come from
# 01-core/versions.env (BINARYEN_VERSION, BINARYEN_<PLATFORM>_<ARCH>_SHA256) so
# the pin is shared with the PowerShell twin
# (windows/scripts/modules/WindowsWasmOpt.Common.psm1) instead of being
# duplicated per language. Both may be overridden from the environment, which is
# also how a caller pins a different release without editing versions.env.
#
# This library is project-agnostic: the size budget, crate name and output paths
# stay in the consuming script. It deliberately does NOT set -e / -u / -o
# pipefail so that sourcing it cannot change the caller's shell options.
#
# Usage:
#   source "<containerhub>/linux/scripts/lib/wasm-opt.sh"
#   wasm_opt_ensure                              # bootstraps if needed
#   wasm_opt_optimize in.wasm out.wasm [-Oz]     # feature flags + fallback

[ -n "${_WASM_OPT_SH_LOADED:-}" ] && return 0
_WASM_OPT_SH_LOADED=1

_WASM_OPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_WASM_OPT_CORE_DIR="${_WASM_OPT_LIB_DIR}/../01-core"
# shellcheck source=./log-bootstrap.sh
source "${_WASM_OPT_LIB_DIR}/log-bootstrap.sh"

# The wasm features wgpu/naga-style codegen emits: bulk-memory,
# nontrapping-float-to-int, sign-extension and simd instructions among them.
# The names are exactly what wasm-opt's validator asks for in its error
# messages. --all-features is the fallback (see wasm_opt_optimize) if a future
# codegen change needs a feature not listed here.
WASM_OPT_FEATURE_FLAGS=(
  --enable-bulk-memory-opt
  --enable-nontrapping-float-to-int
  --enable-simd
  --enable-sign-ext
  --enable-reference-types
  --enable-mutable-globals
  --enable-multivalue
)

# wasm_opt_load_pin - export BINARYEN_VERSION and BINARYEN_*_SHA256 from
# versions.env unless they are already set in the environment.
wasm_opt_load_pin() {
  local versions_file="${1:-${_WASM_OPT_CORE_DIR}/versions.env}"

  if [[ -f "${_WASM_OPT_CORE_DIR}/load-versions-env.sh" ]]; then
    # shellcheck source=../01-core/load-versions-env.sh
    source "${_WASM_OPT_CORE_DIR}/load-versions-env.sh"
    load_versions_env "${versions_file}"
    return 0
  fi

  # Standalone fallback (library copied out of the tree): read just the keys we
  # need. versions.env is inert KEY=value data and must never be `source`d.
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

# wasm_opt_asset_name [version] - binaryen release asset for the running
# platform, e.g. binaryen-version_131-x86_64-linux.tar.gz.
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

# wasm_opt_expected_sha [version] - the pinned checksum matching
# wasm_opt_asset_name. Only the architectures actually pinned in versions.env
# are supported; anything else is a hard error rather than an unverified
# download.
wasm_opt_expected_sha() {
  local machine
  machine="$(uname -m)"
  case "${machine}" in
    x86_64|amd64) printf '%s\n' "${BINARYEN_LINUX_X86_64_SHA256:-}" ;;
    aarch64|arm64) printf '%s\n' "${BINARYEN_LINUX_AARCH64_SHA256:-}" ;;
    *) printf '\n' ;;
  esac
}

# wasm_opt_ensure - make wasm-opt available on PATH, fetching the pinned
# binaryen release if it is not already there.
#
# The extraction directory is a stable, version-keyed cache
# (WASM_OPT_CACHE_DIR, default ${TMPDIR:-/tmp}) rather than a fresh mktemp -d,
# so repeated runs on the same machine (a CI job with a warm workspace, a
# developer iterating locally) reuse the download instead of re-fetching ~10 MB
# every time. A cache hit is decided by the presence of bin/wasm-opt inside the
# version-keyed directory, so bumping BINARYEN_VERSION never reuses a stale
# binary.
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
    # SHA-verified download comes from ContainerHub 01-core (download_verified_file).
    if ! declare -F download_verified_file >/dev/null 2>&1; then
      # shellcheck source=../01-core/downloads.sh
      source "${_WASM_OPT_CORE_DIR}/downloads.sh" 2>/dev/null \
        || err "ContainerHub downloads.sh not available for verified binaryen fetch"
    fi

    mkdir -p "${cache_root}" || err "Cannot create binaryen cache directory ${cache_root}"
    local tmp_dir
    tmp_dir="$(mktemp -d)" || err "mktemp -d failed"
    # Stop at a failed/failing-checksum download rather than falling through to
    # tar, which would only report "cannot open" and bury the real cause.
    if ! download_verified_file \
      "https://github.com/WebAssembly/binaryen/releases/download/${BINARYEN_VERSION}/${asset}" \
      "${expected_sha}" \
      "${tmp_dir}/${asset}"; then
      rm -rf "${tmp_dir}"
      err "Verified download of ${asset} failed (checksum mismatch or network error)."
    fi
    # Extract into the cache root: the tarball's top-level directory is already
    # binaryen-${BINARYEN_VERSION}, i.e. exactly ${install_dir}.
    tar -xzf "${tmp_dir}/${asset}" -C "${cache_root}" || { rm -rf "${tmp_dir}"; err "Extracting ${asset} failed"; }
    rm -rf "${tmp_dir}"
  else
    info "Reusing cached binaryen ${BINARYEN_VERSION} from ${install_dir}"
  fi

  [[ -x "${install_dir}/bin/wasm-opt" ]] || err "wasm-opt missing in ${install_dir}/bin after bootstrap."
  export PATH="${install_dir}/bin:${PATH}"
}

# wasm_opt_optimize <input> <output> [level] - run wasm-opt with the feature
# flags above, retrying once with --all-features if the explicit set is not
# enough (a newer codegen emitting a feature this list predates).
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
