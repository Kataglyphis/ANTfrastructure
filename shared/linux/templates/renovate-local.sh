#!/usr/bin/env bash
# renovate-local.sh — dependency upgrades for THIS repo. Copy and edit.
#
# A WRAPPER, nothing else. The tool — the pinned Node/Renovate bootstrap, the
# report parse, the apply half and every refusal it makes — lives upstream in
# ANTfrastructure's linux/scripts/renovate-local.sh, and is documented once in
# docs/dependency-updates.md. Do not restate any of that here: seven copies of
# this file existed, their headers had grown to between 50 and 106 lines each,
# and each had a different half of the same explanation, most of it stale.
#
# ---- the per-repo slot: two or three lines, and only what is TRUE HERE -------
# What --apply may move in this repo, and what stays hand-edited. Example:
#   --apply moves gitlinks and edits pubspec.yaml; the sqlite3.wasm pin is NOT
#   a Renovate manager and moves with setup-sqlite3-wasm.sh instead.
# -----------------------------------------------------------------------------
#
# Usage is the upstream script's own, forwarded:
#   bash scripts/linux/renovate-local.sh                    # report
#   bash scripts/linux/renovate-local.sh --apply --dry-run  # the plan
#   bash scripts/linux/renovate-local.sh --apply            # write it
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ADJUST: where this repo keeps the bootstrap copy (scripts/linux/lib/ in the
# platform-split consumers, scripts/lib/ in the flat Flutter ones).
source "${_SCRIPT_DIR}/lib/antfrastructure.sh"

# GITHUB_COM_TOKEN, not RENOVATE_TOKEN: --platform=local reads the former for
# GitHub-hosted dependencies, and the latter applies only to --platform=github.
# Without it the GitHub-hosted managers are rate-limited into reporting nothing,
# which looks exactly like "nothing is behind".
if [ -z "${GITHUB_COM_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
  GITHUB_COM_TOKEN="$(gh auth token 2>/dev/null || true)"
  export GITHUB_COM_TOKEN
fi

# No precondition block here. Every check the copies used to re-implement --
# "is node present", "is the submodule checked out", "is the tree clean" -- is
# upstream, where it is tested, and a second copy only ever disagrees with it.
antfrastructure_exec linux/scripts/renovate-local.sh "$KATAGLYPHIS_REPO_ROOT" "$@"
