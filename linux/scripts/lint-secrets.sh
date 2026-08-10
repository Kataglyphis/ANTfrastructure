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
# gitleaks bootstrap: PATH copy preferred; else the pinned release is
# downloaded once into a version-keyed cache dir and SHA256-verified — the
# same pattern as lint-dockerfiles.sh/hadolint. PIN lives here for now —
# MOVE to versions.env as GITLEAKS_VERSION/_SHA256 on the next Batch-3
# window (versions.env edits invalidate the media chain).
#
# Usage: linux/scripts/lint-secrets.sh [path ...]   (no args = repo root)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}" || exit 1

GITLEAKS_PIN="8.30.1"   # versions.env rider — see header
GITLEAKS_SHA256_X64="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# gitleaks bootstrap (PATH copy preferred; else pinned, SHA-verified download)
# ---------------------------------------------------------------------------
GITLEAKS=""
if command -v gitleaks >/dev/null 2>&1; then
  GITLEAKS="$(command -v gitleaks)"
else
  case "$(uname -m)" in
    x86_64) _asset="gitleaks_${GITLEAKS_PIN}_linux_x64.tar.gz"; _sha="${GITLEAKS_SHA256_X64}" ;;
    *) err "no gitleaks on PATH and no pinned asset for $(uname -m) — install gitleaks" ;;
  esac
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
# Tree scan — ENFORCING. The initial run on 2026-08-10 was clean, so there is
# no adoption ramp to pay: any finding is either a real leak (rotate + purge)
# or a false positive (add a .gitleaksignore entry WITH a comment).
# ---------------------------------------------------------------------------
echo "== secret scan: gitleaks ${GITLEAKS_PIN} (working tree) =="
if "${GITLEAKS}" detect --no-git --source "${1:-.}" --no-banner --redact; then
  echo "secret scan: clean"
  exit 0
fi
echo "" >&2
err "gitleaks found potential secrets (redacted above). Real leak -> rotate the credential and purge; false positive -> add a .gitleaksignore entry with a justification comment."
