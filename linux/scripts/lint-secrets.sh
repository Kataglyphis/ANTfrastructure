#!/usr/bin/env bash
# lint-secrets.sh — secret-scanning gate: gitleaks. Closes the last gate
# asymmetry (backlog 2026-08-10 SEC1): shell, Dockerfiles, workflows,
# PowerShell and Python all have lint gates — committed secrets had none.
#
# Scan scope: the WORKING TREE (gitleaks detect --no-git), not git history —
# tree scans are fast, deterministic, and gate what the NEXT commit would
# ship. (A one-time full-history scan is a separate, manual exercise:
#   gitleaks detect --source . --log-opts="--all"
# — run it once, triage, then rely on this tree gate.)
#
# Consumer repos: the scan root is the argument, and so is the rule config —
# a consumer that ships its own .gitleaks.toml is graded by ITS allowlist, not
# by the hub's. Only a consumer WITHOUT one falls back to the hub config.
#
# gitleaks bootstrap: PATH copy preferred; else the pinned release is
# downloaded once into a version-keyed cache dir and SHA256-verified — the
# same pattern as lint-dockerfiles.sh/hadolint. The pin now lives in
# 01-core/versions.env (GITLEAKS_VERSION / GITLEAKS_LINUX_*_SHA256); this
# script no longer carries a second copy of the version.
#
# Usage: linux/scripts/lint-secrets.sh [path]   (no args = repo root)
set -uo pipefail

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# The tree to grade. Everything below — the scan itself AND the rule config —
# is scoped to it; see tests/test-secret-scan.sh, case
# "secret-scan.scope-is-the-argument".
# Resolved to an ABSOLUTE path against the CALLER's cwd and BEFORE the cd below.
# The natural consumer invocation is a relative one from the consumer's own root
# (third_party/ContainerHub/linux/scripts/lint-secrets.sh .), and resolving it
# after the cd re-anchored both the scan and the config lookup inside the hub
# checkout — so the consumer's tree was never graded at all.
SCAN_ROOT="$(cd "${1:-${REPO_ROOT}}" 2>/dev/null && pwd)" || err "scan root not found: ${1:-.}"

cd "${REPO_ROOT}" || err "cannot enter the hub checkout: ${REPO_ROOT}"

CORE_DIR="${REPO_ROOT}/linux/scripts/01-core"

# ---------------------------------------------------------------------------
# Pin (versions.env is the single source of truth)
# ---------------------------------------------------------------------------
gitleaks_load_pin() {
  # shellcheck source=01-core/load-versions-env.sh
  source "${CORE_DIR}/load-versions-env.sh" \
    || err "load-versions-env.sh not available; cannot resolve the gitleaks pin"
  load_versions_env "${CORE_DIR}/versions.env"
  # NOTE for test authors: the pin is READ FROM versions.env, so extract it
  # from there (sed -n 's/^GITLEAKS_VERSION=//p' 01-core/versions.env), never
  # by grepping this file for a literal.
  GITLEAKS_PIN="${GITLEAKS_VERSION:-}"
  [ -n "${GITLEAKS_PIN}" ] \
    || err "GITLEAKS_VERSION is not set (${CORE_DIR}/versions.env not found?)."
}

# Prints "<asset name> <expected sha256>"; nonzero on an unsupported arch.
gitleaks_asset_and_sha() {
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

# ---------------------------------------------------------------------------
# gitleaks bootstrap (PATH copy preferred; else pinned, SHA-verified download)
# ---------------------------------------------------------------------------
GITLEAKS=""
if command -v gitleaks >/dev/null 2>&1; then
  GITLEAKS="$(command -v gitleaks)"
else
  read -r _asset _sha < <(gitleaks_asset_and_sha) \
    || err "no gitleaks on PATH and no pinned asset for $(uname -m) — install gitleaks"
  [ -n "${_sha}" ] \
    || err "No pinned gitleaks SHA256 for ${_asset}; add one to ${CORE_DIR}/versions.env."
  _cache="${XDG_CACHE_HOME:-${HOME}/.cache}/kataglyphis-lint/gitleaks-${GITLEAKS_PIN}"
  GITLEAKS="${_cache}/gitleaks"
  if [ ! -x "${GITLEAKS}" ]; then
    mkdir -p "${_cache}"
    _url="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_PIN}/${_asset}"
    echo "bootstrapping gitleaks ${GITLEAKS_PIN} (pinned, SHA-verified) ..."
    curl -fsSL --retry 3 -o "${_cache}/${_asset}" "${_url}" || err "gitleaks download failed"
    echo "${_sha}  ${_cache}/${_asset}" | sha256sum -c - >/dev/null 2>&1 \
      || err "gitleaks tarball SHA256 mismatch (expected ${_sha})"
    tar -xzf "${_cache}/${_asset}" -C "${_cache}" gitleaks || err "gitleaks extract failed"
    rm -f "${_cache}/${_asset}"
    [ -x "${GITLEAKS}" ] || err "gitleaks binary missing after extract"
  fi
fi

# ---------------------------------------------------------------------------
# Rule config: the scanned tree's own .gitleaks.toml wins. A consumer repo has
# its own allowlist entries (each with a written justification) and the hub's
# say nothing about ITS false positives — grading a consumer tree by the hub
# config is the same category of error as scanning the wrong tree.
# ---------------------------------------------------------------------------
if [ -f "${SCAN_ROOT}/.gitleaks.toml" ]; then
  CONFIG="${SCAN_ROOT}/.gitleaks.toml"
else
  CONFIG="${REPO_ROOT}/.gitleaks.toml"
fi

# ---------------------------------------------------------------------------
# Tree scan — ENFORCING. The initial run on 2026-08-10 was clean, so there is
# no adoption ramp to pay: any finding is either a real leak (rotate + purge)
# or a false positive (add a .gitleaksignore entry WITH a comment).
# ---------------------------------------------------------------------------
echo "== secret scan: gitleaks ${GITLEAKS_PIN} (working tree) =="
echo "   scan root: ${SCAN_ROOT}"
echo "   config:    ${CONFIG}"
# --verbose PRINTS the findings; without it "leaks found: N" names none.
# --redact keeps the values out of the log. Source AND config are spelled the
# same way on purpose: gitleaks matches allowlist paths, and skips its own
# config, only when they are.
# docs/code-quality-tooling.md#the-secret-scan-scans-from-inside-the-tree
_CONFIG_ARG="${CONFIG}"
[ "${CONFIG}" = "${SCAN_ROOT}/.gitleaks.toml" ] && _CONFIG_ARG=".gitleaks.toml"
if ( cd "${SCAN_ROOT}" && "${GITLEAKS}" detect --no-git --source . \
     --config "${_CONFIG_ARG}" --no-banner --redact --verbose ); then
  echo "secret scan: clean"
  exit 0
fi
echo "" >&2
err "gitleaks found potential secrets (values redacted, file:line shown above). Real leak -> rotate the credential and purge; false positive -> add an allowlist entry (with justification) to .gitleaks.toml."
