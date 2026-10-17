#!/usr/bin/env bash
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Move a checkout and its submodules onto their remote's rewritten history and drop the old objects. See docs/adopting-in-a-new-project.md#after-a-history-rewrite
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: git-adopt-rewritten-history.sh [--dry-run] [--backup DIR] [CHECKOUT...]

For a checkout (default: the current directory) and every initialized submodule:
saves the work only it has under --backup (uncommitted changes, stashes, commits
that never reached origin, local-only tags), points each branch that tracks
origin at its rewritten remote branch, moves detached submodules to the new
gitlinks, re-applies the uncommitted changes, then expires the reflogs and runs
gc, so the old blobs leave the disk too. A local commit counts as rewritten when
origin has its twin (same author, author date and subject), so an earlier fetch
does not hide the rewrite. A repository whose remote was not rewritten is only
fast-forwarded and keeps its reflogs.

  --backup DIR  where saved work goes (default: ~/git-rewrite-backup/<timestamp>)
  --dry-run     print the plan, change nothing, save nothing
EOF
}

dry=0
backup="${HOME}/git-rewrite-backup/$(date +%Y%m%d-%H%M%S)"
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --backup) backup="${2:?--backup needs a directory}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
[ ${#args[@]} -gt 0 ] || args=(.)

say() { printf '%s\n' "$*"; return 0; }
run() { if [ "${dry}" -eq 1 ]; then say "    would run: $*"; else "$@"; fi; }
# Per repository directory: whether it had uncommitted changes when the run began, and whether this run reset its working tree.
declare -A DIRTY=() RESET=()

# save_dir <label>: the backup directory of one repository.
save_dir() { local l="$1"; printf '%s/%s' "${backup}" "${l//\//_}"; }

# record <dir> <label>: saves what a reset would lose, before any submodule update touches the working trees.
record() {
  local dir="$1" label="$2" save n i
  [ -n "${DIRTY[${dir}]+set}" ] && return 0
  save="$(save_dir "${label}")"
  DIRTY[${dir}]=0
  # A submodule's own changes are saved in its own patch; its "-dirty" gitlink line would not apply here.
  if ! git -C "${dir}" diff --quiet --ignore-submodules=all HEAD -- 2>/dev/null; then
    DIRTY[${dir}]=1
    if [ "${dry}" -eq 1 ]; then
      say "  ${label}: has uncommitted changes, would save them to ${save}/uncommitted.patch"
    else
      mkdir -p "${save}"
      git -C "${dir}" diff --binary --ignore-submodules=all HEAD > "${save}/uncommitted.patch"
      say "  ${label}: uncommitted changes saved to ${save}/uncommitted.patch"
    fi
  fi
  n="$(git -C "${dir}" stash list | wc -l)"
  if [ "${n}" -gt 0 ] && [ "${dry}" -eq 0 ]; then
    mkdir -p "${save}"
    for ((i = 0; i < n; i++)); do
      git -C "${dir}" stash show --include-untracked -p --binary "stash@{${i}}" > "${save}/stash-${i}.patch" 2>/dev/null ||
        git -C "${dir}" stash show -p --binary "stash@{${i}}" > "${save}/stash-${i}.patch"
    done
  fi
  [ "${n}" -gt 0 ] && say "  ${label}: ${n} stash entr(ies)$([ "${dry}" -eq 1 ] && printf ' would be') saved as ${save}/stash-*.patch"
  return 0
}

# record_tree <dir> <label>: record() for a repository and every initialized submodule below it.
record_tree() {
  local dir="$1" label="$2" sub
  record "${dir}" "${label}"
  [ -f "${dir}/.gitmodules" ] || return 0
  while IFS= read -r sub; do
    [ -n "${sub}" ] && [ -e "${dir}/${sub}/.git" ] && record_tree "${dir}/${sub}" "${label}/${sub}"
  done < <(git -C "${dir}" config -f .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}')
  return 0
}

# local_commits <dir> <rev...>: "sha twin" per commit only the revs reach; twin 1 = origin has its rewrite (same author, date, subject).
local_commits() {
  local dir="$1"; shift
  awk -F'\t' 'NR == FNR { seen[$2] = 1; next } { print $1, ($2 in seen) ? 1 : 0 }' \
    <(git -C "${dir}" log --remotes=origin --format='%H%x09%an <%ae> %at %s') \
    <(git -C "${dir}" log --reverse --format='%H%x09%an <%ae> %at %s' "$@" --not --remotes=origin --)
}

# save_unpushed <dir> <label> <branch> <old>: the branch's commits that never reached origin, as patches.
save_unpushed() {
  local dir="$1" label="$2" branch="$3" old="$4" out sha twin n=0
  local mine=()
  out="$(save_dir "${label}")/${branch//\//_}"
  while read -r sha twin; do
    if [ "${twin}" -eq 0 ]; then mine+=("${sha}"); fi
  done < <(local_commits "${dir}" "${old}")
  [ ${#mine[@]} -gt 0 ] || return 0
  if [ "${dry}" -eq 0 ]; then
    for sha in "${mine[@]}"; do
      n=$((n + 1))
      git -C "${dir}" format-patch --quiet -1 --start-number "${n}" -o "${out}" "${sha}"
    done
  fi
  say "  ${label}: ${branch} has ${#mine[@]} commit(s) that never reached origin$([ "${dry}" -eq 1 ] && printf ', would be') saved as patches in ${out}"
}

# move_branch <dir> <label> <branch> <upstream> <rewritten> <head-branch>: one local branch onto its remote branch.
move_branch() {
  local dir="$1" label="$2" branch="$3" upstream="$4" rewritten="$5" head_ref="$6" old new
  if ! git -C "${dir}" rev-parse -q --verify "refs/remotes/${upstream}" >/dev/null; then
    say "  ${label}: ${branch}'s ${upstream} is gone, branch left alone"
    return 0
  fi
  old="$(git -C "${dir}" rev-parse "refs/heads/${branch}")"
  new="$(git -C "${dir}" rev-parse "refs/remotes/${upstream}")"
  [ "${old}" != "${new}" ] || return 0
  if git -C "${dir}" merge-base --is-ancestor "${old}" "${new}"; then
    say "  ${label}: ${branch} fast-forwards to ${new:0:10}"
  elif [ "${rewritten}" -eq 0 ]; then
    say "  ${label}: ${branch} has diverged from ${upstream} on a history that was not rewritten, left alone"
    return 0
  else
    save_unpushed "${dir}" "${label}" "${branch}" "${old}"
    say "  ${label}: ${branch} moves to the rewritten ${upstream} (${old:0:10} -> ${new:0:10})"
  fi
  if [ "${branch}" = "${head_ref}" ]; then
    run git -C "${dir}" reset --quiet --hard "${new}"
    RESET[${dir}]=1
  else
    run git -C "${dir}" branch --quiet -f "${branch}" "${new}"
  fi
  return 0
}

# reapply <dir> <label>: the uncommitted changes record saved, once this run has reset that working tree.
reapply() {
  local dir="$1" label="$2" patch
  patch="$(save_dir "${label}")/uncommitted.patch"
  if [ "${DIRTY[${dir}]}" -eq 0 ] || [ -z "${RESET[${dir}]:-}" ] || [ "${dry}" -eq 1 ]; then return 0; fi
  if git -C "${dir}" apply --3way --whitespace=nowarn "${patch}" 2>/dev/null; then
    say "  ${label}: uncommitted changes re-applied (and staged)"
  else
    say "  ${label}: the uncommitted changes did not apply cleanly; they stay in ${patch}"
  fi
}

# adopt_submodules <dir> <label>: every initialized submodule, after its superproject moved.
adopt_submodules() {
  local dir="$1" label="$2" sub
  local subs=()
  [ -f "${dir}/.gitmodules" ] || return 0
  mapfile -t subs < <(git -C "${dir}" config -f .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}')
  run git -C "${dir}" submodule sync --quiet
  for sub in "${subs[@]}"; do
    [ -e "${dir}/${sub}/.git" ] || continue
    # A detached submodule follows the new gitlink; one on a branch moves with that branch in its own adopt.
    if ! git -C "${dir}/${sub}" symbolic-ref -q HEAD >/dev/null &&
      [ "$(git -C "${dir}" ls-tree HEAD -- "${sub}" | awk '{print $3}')" != "$(git -C "${dir}/${sub}" rev-parse HEAD)" ]; then
      run git -C "${dir}" submodule update --quiet --force -- "${sub}"
      RESET[${dir}/${sub}]=1
    fi
    adopt "${dir}/${sub}" "${label}/${sub}"
  done
  return 0
}

# drop_local_tags <dir> <label>: a tag only this checkout has would keep the old commits, and their blobs, alive.
drop_local_tags() {
  local dir="$1" label="$2" save tag sha ref
  local gone=()
  declare -A on_origin=()
  save="$(save_dir "${label}")"
  while read -r _ ref; do on_origin[${ref#refs/tags/}]=1; done < <(git -C "${dir}" ls-remote --tags --refs origin)
  while read -r tag; do
    [ -z "${on_origin[${tag}]+set}" ] || continue
    sha="$(git -C "${dir}" rev-parse "${tag}^{commit}" 2>/dev/null)" || continue
    if [ -n "$(git -C "${dir}" rev-list -n 1 "${sha}" --not --remotes=origin --)" ]; then gone+=("${tag} ${sha}"); fi
  done < <(git -C "${dir}" for-each-ref --format='%(refname:short)' refs/tags)
  [ ${#gone[@]} -gt 0 ] || return 0
  if [ "${dry}" -eq 0 ]; then mkdir -p "${save}"; printf '%s\n' "${gone[@]}" > "${save}/local-tags.txt"; fi
  say "  ${label}: ${#gone[@]} tag(s) only here name old commits; listed in ${save}/local-tags.txt and deleted"
  for tag in "${gone[@]}"; do run git -C "${dir}" tag -d "${tag%% *}" >/dev/null; done
  return 0
}

# drop_old_history <dir> <label>: names what may still hold the old commits, then lets gc drop the rest.
drop_old_history() {
  local dir="$1" label="$2" remote tree here
  here="$(cd "${dir}" && pwd -P)"
  while IFS= read -r remote; do
    [ "${remote}" = origin ] || say "  ${label}: remote '${remote}' may still hold the old history; its objects stay until it is removed"
  done < <(git -C "${dir}" remote)
  while IFS= read -r tree; do
    [ "${tree}" = "${here}" ] || say "  ${label}: worktree ${tree} was not moved; adopt it on its own"
  done < <(git -C "${dir}" worktree list --porcelain | awk '/^worktree / {print substr($0, 10)}')
  run git -C "${dir}" stash clear
  run git -C "${dir}" reflog expire --expire=now --all
  run git -C "${dir}" gc --quiet --prune=now
  [ "${dry}" -eq 1 ] || say "  ${label}: old history dropped, $(git -C "${dir}" count-objects -vH | awk '/size-pack/ {print $2 $3}') packed"
  return 0
}

# adopt <dir> <label>: one repository, then its submodules.
adopt() {
  local dir="$1" label="$2" head_ref branch upstream rewritten=0
  git -C "${dir}" fetch --quiet --prune --force --tags --no-recurse-submodules origin
  if local_commits "${dir}" HEAD --branches | grep -q ' 1$'; then
    rewritten=1
    say "  ${label}: origin's history was rewritten"
  fi
  head_ref="$(git -C "${dir}" symbolic-ref -q --short HEAD || true)"
  while IFS=' ' read -r branch upstream; do
    case "${upstream}" in
      origin/*) move_branch "${dir}" "${label}" "${branch}" "${upstream}" "${rewritten}" "${head_ref}" ;;
    esac
  done < <(git -C "${dir}" for-each-ref --format='%(refname:short) %(upstream:short)' refs/heads)
  reapply "${dir}" "${label}"
  adopt_submodules "${dir}" "${label}"
  [ "${rewritten}" -eq 1 ] || return 0
  drop_local_tags "${dir}" "${label}"
  drop_old_history "${dir}" "${label}"
  return 0
}

for checkout in "${args[@]}"; do
  top="$(git -C "${checkout}" rev-parse --show-toplevel)"
  say "== ${top}"
  # Every working tree is saved before the first submodule update overwrites one.
  record_tree "${top}" "$(basename "${top}")"
  adopt "${top}" "$(basename "${top}")"
done
[ -d "${backup}" ] && say "saved work: ${backup}"
exit 0
