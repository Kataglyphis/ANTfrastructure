#!/usr/bin/env bash
# lint-workflows.sh — actionlint over .github/workflows/*.yml (composite
# actions under .github/actions are pulled in automatically when referenced).
#
# actionlint is bootstrapped on demand: PATH copy preferred, otherwise the
# pinned release (ACTIONLINT_VERSION / ACTIONLINT_*_SHA256 in versions.env) is
# downloaded once into a version-keyed cache dir and SHA256-verified — the same
# pattern as lint-dockerfiles.sh / lib/wasm-opt.sh.
#
# Usage: linux/scripts/lint-workflows.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}" || exit 1

CORE_DIR="${REPO_ROOT}/linux/scripts/01-core"

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

actionlint_asset_and_sha() {
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64|Linux/amd64)
      printf 'actionlint_%s_linux_amd64.tar.gz %s\n' "${ACTIONLINT_VERSION}" "${ACTIONLINT_LINUX_AMD64_SHA256:-}" ;;
    Linux/aarch64|Linux/arm64)
      printf 'actionlint_%s_linux_arm64.tar.gz %s\n' "${ACTIONLINT_VERSION}" "${ACTIONLINT_LINUX_ARM64_SHA256:-}" ;;
    MINGW*/x86_64|MSYS*/x86_64|CYGWIN*/x86_64)
      printf 'actionlint_%s_windows_amd64.zip %s\n' "${ACTIONLINT_VERSION}" "${ACTIONLINT_WINDOWS_AMD64_SHA256:-}" ;;
    *) return 1 ;;
  esac
}

actionlint_ensure() {
  if command -v actionlint >/dev/null 2>&1; then
    ACTIONLINT_BIN="$(command -v actionlint)"
    return 0
  fi

  # shellcheck source=01-core/load-versions-env.sh
  source "${CORE_DIR}/load-versions-env.sh"
  load_versions_env "${CORE_DIR}/versions.env"
  [ -n "${ACTIONLINT_VERSION:-}" ] || err "ACTIONLINT_VERSION is not set (versions.env not found?)."

  local asset expected_sha cache_root archive bin_name
  read -r asset expected_sha < <(actionlint_asset_and_sha) \
    || err "Unsupported platform for actionlint bootstrap ($(uname -s)/$(uname -m)); install actionlint on PATH instead."
  [ -n "${expected_sha}" ] || err "No pinned actionlint SHA256 for ${asset}; add one to versions.env."

  cache_root="${ACTIONLINT_CACHE_DIR:-${TMPDIR:-/tmp}}/actionlint-${ACTIONLINT_VERSION}"
  bin_name="actionlint"; case "${asset}" in *windows*) bin_name="actionlint.exe" ;; esac
  ACTIONLINT_BIN="${cache_root}/${bin_name}"

  if [ ! -x "${ACTIONLINT_BIN}" ]; then
    # shellcheck source=01-core/downloads.sh
    source "${CORE_DIR}/downloads.sh" || err "downloads.sh not available for verified actionlint fetch"
    mkdir -p "${cache_root}" || err "Cannot create actionlint cache directory ${cache_root}"
    archive="${cache_root}/${asset}"
    download_verified_file \
      "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/${asset}" \
      "${expected_sha}" \
      "${archive}" \
      || err "Verified download of ${asset} failed (checksum mismatch or network error)."
    case "${asset}" in
      *.tar.gz) tar -xzf "${archive}" -C "${cache_root}" "${bin_name}" || err "Extraction of ${asset} failed." ;;
      *.zip)    unzip -oq "${archive}" "${bin_name}" -d "${cache_root}" || err "Extraction of ${asset} failed." ;;
    esac
    rm -f "${archive}"
    chmod +x "${ACTIONLINT_BIN}"
  fi
}

actionlint_ensure
printf '== actionlint (%s) ==\n' "$("${ACTIONLINT_BIN}" --version | head -n1)"

if "${ACTIONLINT_BIN}"; then
  printf 'WORKFLOW LINT OK\n'
else
  printf 'WORKFLOW LINT FAILED\n' >&2
  exit 1
fi
