#!/usr/bin/env bash
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Put a checkout and all its submodules on their branch, fast-forwarded. See docs/adopting-in-a-new-project.md#putting-every-checkout-on-its-branch
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: git-sync-branches.sh [--repo DIR] [--owned-only] [--dry-run]

Checks out the superproject's default branch and, recursively, each submodule's
branch (.gitmodules `branch =`, else the remote's default), fast-forward only.
Working trees only: no gitlink is committed.

  --repo DIR   the superproject (default: the current directory)
  --owned-only leave submodules hosted outside the superproject's owner at their recorded commit
  --dry-run    print the plan, change nothing
EOF
}

# <url> -> the namespace that hosts it: github.com/Owner for both https and scp forms.
url_owner() {
  local u="$1"
  case "${u}" in
    *://*) u="${u#*://}"; u="${u#*@}" ;;
    *@*:*) u="${u#*@}"; u="${u/://}" ;;
  esac
  printf '%s' "${u%/*}"
}

fail() {
  printf 'FAIL  %s: %s\n' "$1" "$2" >&2
  printf 'x\n' >> "${GSB_FAILS}"
}

# sync_one <label> [branch]: an empty branch means the remote's default.
sync_one() {
  local label="$1" branch="${2:-}" old behind
  if ! git fetch --quiet --prune origin; then fail "${label}" "fetch failed"; return 0; fi
  if [ -z "${branch}" ]; then
    git remote set-head origin --auto >/dev/null 2>&1 || true
    branch="$(git symbolic-ref -q --short refs/remotes/origin/HEAD || true)"
    branch="${branch#origin/}"
  fi
  if [ -z "${branch}" ] || ! git rev-parse -q --verify "refs/remotes/origin/${branch}" >/dev/null; then
    fail "${label}" "origin has no branch '${branch:-<default>}'"; return 0
  fi
  # Gitlink moves in a parent are this script's own doing; only file edits block it.
  if [ -n "$(git status --porcelain --untracked-files=no --ignore-submodules=all)" ]; then
    printf 'SKIP  %s: uncommitted changes\n' "${label}" >&2; return 0
  fi
  old="$(git rev-parse --short HEAD)"
  behind="$(git rev-list --count "HEAD..origin/${branch}")"
  if [ "${GSB_DRY}" = 1 ]; then
    printf 'PLAN  %s: %s at %s, %s behind origin/%s\n' "${label}" "$(git rev-parse --abbrev-ref HEAD)" "${old}" "${behind}" "${branch}"
    return 0
  fi
  if git show-ref -q --verify "refs/heads/${branch}"; then
    git checkout -q "${branch}"
  else
    git checkout -q -b "${branch}" --track "origin/${branch}"
  fi
  if ! git merge -q --ff-only "origin/${branch}" 2>/dev/null; then
    fail "${label}" "${branch} has diverged from origin/${branch}"; return 0
  fi
  printf 'OK    %s: %s %s -> %s\n' "${label}" "${branch}" "${old}" "$(git rev-parse --short HEAD)"
}

# Runs inside `git submodule foreach`, which exports name, toplevel and displaypath.
# shellcheck disable=SC2154
sync_submodule() {
  local branch
  if [ "${GSB_OWNED_ONLY}" = 1 ] && [ "$(url_owner "$(git remote get-url origin)")" != "${GSB_OWNER}" ]; then
    printf 'PIN   %s: not under %s, left at its recorded commit\n' "${displaypath}" "${GSB_OWNER}"
    return 0
  fi
  branch="$(git config -f "${toplevel}/.gitmodules" "submodule.${name}.branch" || true)"
  if [ "${branch}" = . ]; then branch="$(git -C "${toplevel}" symbolic-ref -q --short HEAD || true)"; fi
  sync_one "${displaypath}" "${branch}"
}

parse_args() {
  GSB_REPO=. GSB_OWNED_ONLY=0 GSB_DRY=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --owned-only) GSB_OWNED_ONLY=1 ;;
      --dry-run) GSB_DRY=1 ;;
      --repo) GSB_REPO="${2:?--repo needs a directory}"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
}

main() {
  local self drift
  parse_args "$@"
  self="$(realpath "${BASH_SOURCE[0]}")"
  cd "${GSB_REPO}"
  GSB_OWNER="$(url_owner "$(git remote get-url origin)")"
  GSB_FAILS="$(mktemp)"
  export GSB_OWNED_ONLY GSB_DRY GSB_OWNER GSB_FAILS
  sync_one . ""
  git submodule foreach --quiet --recursive "bash '${self}' --submodule"
  drift="$(git submodule status --recursive | sed -n 's/^+[0-9a-f]* \([^ ]*\).*/\1/p')"
  if [ -n "${drift}" ] && [ "${GSB_DRY}" = 0 ]; then
    printf '\nNot the recorded commit any more (commit the gitlinks to keep, or %s to go back):\n%s\n' \
      'git submodule update --checkout --recursive' "${drift}"
  fi
  if [ -s "${GSB_FAILS}" ]; then rm -f "${GSB_FAILS}"; return 1; fi
  rm -f "${GSB_FAILS}"
}

if [ "${1:-}" = --submodule ]; then sync_submodule; else main "$@"; fi
