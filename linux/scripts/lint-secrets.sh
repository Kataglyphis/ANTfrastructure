#!/usr/bin/env bash
# [path] [config]: gitleaks over the working tree, not history, so it gates what the next commit ships.
set -uo pipefail

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Resolve against the caller's cwd before the cd below, or a relative consumer root lands in the hub.

# A file is a legal scan root: consumers scan top-level entries one at a time to skip vendored trees.
if [ -f "${1:-}" ]; then
  SCAN_ROOT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
else
  SCAN_ROOT="$(cd "${1:-${REPO_ROOT}}" 2>/dev/null && pwd)" || err "scan root not found: ${1:-.}"
fi

# The .gitleaks.toml probe below wants a DIRECTORY to look in.
SCAN_CONFIG_DIR="${SCAN_ROOT}"
[ -d "${SCAN_CONFIG_DIR}" ] || SCAN_CONFIG_DIR="$(dirname "${SCAN_ROOT}")"

# Resolved before the cd too: the probe only finds a .gitleaks.toml at the scanned path itself.
CONFIG_ARG=""
if [ -n "${2:-}" ]; then
  [ -f "$2" ] || err "gitleaks config not found: $2"
  CONFIG_ARG="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
fi

cd "${REPO_ROOT}" || err "cannot enter the hub checkout: ${REPO_ROOT}"

CORE_DIR="${REPO_ROOT}/linux/scripts/01-core"

# Pin: tool-pins.env is the single source of truth
gitleaks_load_pin() {
  # shellcheck source=01-core/load-versions-env.sh
  source "${CORE_DIR}/load-versions-env.sh" \
    || err "load-versions-env.sh not available; cannot resolve the gitleaks pin"
  load_versions_env "${CORE_DIR}/tool-pins.env"
  # Tests read the pin from tool-pins.env; this file carries no literal to grep.
  GITLEAKS_PIN="${GITLEAKS_VERSION:-}"
  [ -n "${GITLEAKS_PIN}" ] \
    || err "GITLEAKS_VERSION is not set (${CORE_DIR}/tool-pins.env not found?)."
}

# Prints "<asset name> <expected sha256>"; nonzero on an unsupported arch.
gitleaks_asset_and_sha() {
  # Git Bash reports x86_64 too, and the Linux binary then dies with "Exec format error".
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      printf 'gitleaks_%s_windows_x64.zip %s\n' "${GITLEAKS_PIN}" "${GITLEAKS_WINDOWS_X64_SHA256:-}"
      return 0 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)
      printf 'gitleaks_%s_linux_x64.tar.gz %s\n' \
        "${GITLEAKS_PIN}" "${GITLEAKS_LINUX_X64_SHA256:-}" ;;
    aarch64|arm64)
      printf 'gitleaks_%s_linux_arm64.tar.gz %s\n' \
        "${GITLEAKS_PIN}" "${GITLEAKS_LINUX_ARM64_SHA256:-}" ;;
    *) return 1 ;;
  esac
}

gitleaks_load_pin

# gitleaks bootstrap: PATH copy preferred, else a pinned, SHA-verified download
GITLEAKS=""
if command -v gitleaks >/dev/null 2>&1; then
  GITLEAKS="$(command -v gitleaks)"
else
  read -r _asset _sha < <(gitleaks_asset_and_sha) \
    || err "no gitleaks on PATH and no pinned asset for $(uname -m) — install gitleaks"
  [ -n "${_sha}" ] \
    || err "No pinned gitleaks SHA256 for ${_asset}; add one to ${CORE_DIR}/tool-pins.env."
  _cache="${XDG_CACHE_HOME:-${HOME}/.cache}/kataglyphis-lint/gitleaks-${GITLEAKS_PIN}"
  _bin="gitleaks"; case "${_asset}" in *.zip) _bin="gitleaks.exe" ;; esac
  GITLEAKS="${_cache}/${_bin}"
  if [ ! -x "${GITLEAKS}" ]; then
    echo "bootstrapping gitleaks ${GITLEAKS_PIN} (pinned, SHA-verified) ..."
    # shellcheck source=01-core/downloads.sh
    source "${CORE_DIR}/downloads.sh" || err "downloads.sh not available for verified gitleaks fetch"
    # Parallel mutation jobs share this cache; a half-extracted binary once failed a clean scan.
    download_verified_install "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_PIN}/${_asset}" \
      "${_sha}" "${GITLEAKS}" "${_bin}" \
      || err "gitleaks install failed (download, SHA256 ${_sha} or extract)"
  fi
fi

# Rule config: the scanned tree's own .gitleaks.toml wins; the hub's allowlist knows nothing of a consumer's.
if [ -n "${CONFIG_ARG}" ]; then
  CONFIG="${CONFIG_ARG}"
elif [ -f "${SCAN_CONFIG_DIR}/.gitleaks.toml" ]; then
  CONFIG="${SCAN_CONFIG_DIR}/.gitleaks.toml"
else
  CONFIG="${REPO_ROOT}/.gitleaks.toml"
fi

# Tree scan, enforcing: a finding is a leak to rotate or a .gitleaksignore entry with a comment.
echo "== secret scan: gitleaks ${GITLEAKS_PIN} (working tree) =="
echo "   scan root: ${SCAN_ROOT}"
echo "   config:    ${CONFIG}"
# Source and config spelled alike: only then does gitleaks match allowlist paths. docs/code-quality-tooling.md#the-secret-scan-scans-from-inside-the-tree
_CONFIG_ARG="${CONFIG}"
[ "${CONFIG}" = "${SCAN_CONFIG_DIR}/.gitleaks.toml" ] && _CONFIG_ARG=".gitleaks.toml"
# gitleaks must be entered from a directory, so a file target scans from its parent.
_SCAN_DIR="${SCAN_ROOT}"
_SCAN_SRC="."
if [ -f "${SCAN_ROOT}" ]; then
  _SCAN_DIR="$(dirname "${SCAN_ROOT}")"
  _SCAN_SRC="$(basename "${SCAN_ROOT}")"
fi
if ( cd "${_SCAN_DIR}" && "${GITLEAKS}" detect --no-git --source "${_SCAN_SRC}" \
     --config "${_CONFIG_ARG}" --no-banner --redact --verbose ); then
  echo "secret scan: clean"
  exit 0
fi
echo "" >&2
err "gitleaks found potential secrets (values redacted, file:line shown above). Real leak -> rotate the credential and purge; false positive -> add an allowlist entry (with justification) to .gitleaks.toml."
