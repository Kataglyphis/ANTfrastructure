#!/usr/bin/env bash
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# The tree half of renovate-local.sh, sourced by it. See docs/dependency-updates.md#nothing-else-in-the-repo-moved
[ -n "${_RENOVATE_TREE_SH_LOADED:-}" ] && return 0
_RENOVATE_TREE_SH_LOADED=1

# The pre-run snapshot: porcelain lines, their paths (for exact "already dirty" matches), hashes, ignored paths.
TREE_BEFORE=""; TREE_BEFORE_PATHS=""; TREE_BEFORE_HASH=""; TREE_BEFORE_IGNORED=""
TREE_CLASSIFIED=0
# Rows are "<path>\t<what happened>": a TAB, since a path may legally contain the rendered "  (".
TREE_COLLATERAL=()   # moved, this run does not own it, and it was clean before
TREE_UNSAFE=()       # moved, and it was ALREADY dirty -- not ours to put back
TREE_EOL=()          # moved, tracked, and the ONLY difference is line endings
TREE_PUTBACK=()      # collateral proven back where it was
TREE_STUCK=()        # collateral that would not go back
TREE_IGNORED_GONE=() # ignored paths a tool DELETED; no copy of them was taken

# Audited manifest shas: lock tools such as `flutter pub get` rewrite the manifest after the audit.
MANIFEST_SHAS=()

# Is the tree clean enough to write?

# Dirty or just the wrong git; `dirty`, never `all`. See docs/dependency-updates.md#the-nested-submodule-that-no-end-of-line-option-can-reach
classify_one() {
  local dir="$1" pth="$2" label="$3"
  local -a lim=()
  local -a nested=(--ignore-submodules=dirty)
  if [ -n "${pth}" ]; then lim=(-- "${pth}"); fi
  if ! "${GIT_BIN}" -C "${dir}" diff --quiet --ignore-cr-at-eol "${nested[@]}" HEAD ${lim[@]+"${lim[@]}"} 2>/dev/null; then
    APPLY_DIRTY+=("${label}")
  elif ! "${GIT_BIN}" -C "${dir}" diff --quiet "${nested[@]}" HEAD ${lim[@]+"${lim[@]}"} 2>/dev/null; then
    APPLY_EOL+=("${label}")
  fi
}

# Submodule working trees and manifests to edit get the same two questions.
classify_apply_paths() {
  APPLY_DIRTY=(); APPLY_EOL=()
  local q
  for q in ${APPLY_PATHS[@]+"${APPLY_PATHS[@]}"}; do
    [ -e "${TARGET}/${q}/.git" ] || continue          # not initialised; git handles it
    classify_one "${GIT_TARGET}/${q}" "" "${q}"
  done
  for q in ${EDIT_FILES[@]+"${EDIT_FILES[@]}"}; do
    [ -f "${TARGET}/${q}" ] || continue
    classify_one "${GIT_TARGET}" "${q}" "${q}"
  done
}

# On Windows the report needs WSL's node but the checkout needs the git that wrote it, so switch to git.exe.
select_git_for_tree() {
  GIT_BIN=git; GIT_TARGET="${TARGET}"
  classify_apply_paths
  [ "${#APPLY_EOL[@]}" -gt 0 ] || return 0
  command -v git.exe >/dev/null 2>&1 || return 0
  command -v wslpath >/dev/null 2>&1 || return 0

  local win_target
  win_target="$(wslpath -w "${TARGET}" 2>/dev/null || true)"
  [ -n "${win_target}" ] || return 0
  git.exe -C "${win_target}" rev-parse --git-dir >/dev/null 2>&1 || return 0

  GIT_BIN=git.exe
  GIT_TARGET="${win_target}"
  note ""
  note "this tree was checked out by the Windows git; using it for the checkout"
  note "half (${win_target}). A Linux-git checkout over it aborts mid-run."
  classify_apply_paths
}

# Collateral guard: anything moved beyond the rollback's reach (BACKUP_PATHS + APPLY_PATHS) and not ignored.

# status -uall sees created files; no --ignore-submodules, unlike classify_one. See docs/dependency-updates.md#the-same-flag-two-questions
tree_status() {
  "${GIT_BIN}" -C "${GIT_TARGET}" status --porcelain=v1 -uall 2>/dev/null
}

# Undo git's path quoting (a space triggers it); \\ before \" so an escaped backslash is not re-read.
tree_unquote() {
  local s="$1"
  case "${s}" in '"'*'"') ;; *) printf '%s\n' "${s}"; return 0 ;; esac
  s="${s#\"}"; s="${s%\"}"
  s="${s//\\\\/\\0134}"
  s="${s//\\\"/\\0042}"
  printf '%b\n' "${s}"
}

# A path with a newline stays quoted, so it matches nothing owned and refuses.
tree_emit_path() {
  case "$1" in *'\n'*) printf '%s\n' "$1"; return 0 ;; esac
  tree_unquote "$1"
}

# `R  old -> new` names two paths, and both matter.
tree_paths() {
  local line body one two
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    body="${line:3}"
    case "${line:0:1}" in
      R|C) one="${body%% -> *}"; two="${body#* -> }" ;;
      *)   one="${body}"; two="" ;;
    esac
    tree_emit_path "${one}"
    [ -n "${two}" ] && [ "${two}" != "${one}" ] && tree_emit_path "${two}"
  done
  return 0
}

# "<path>  (<what happened>)" for each "<path><TAB><what happened>" row.
tree_row_text() {
  local row
  for row in "$@"; do printf '%s  (%s)\n' "${row%%	*}" "${row#*	}"; done
}

# git is the one binary guaranteed here; --no-filters hashes the bytes on disk, whatever the eol settings.
tree_hash() {
  [ -f "${TARGET}/$1" ] || { printf -- '-\n'; return 0; }
  "${GIT_BIN}" -C "${GIT_TARGET}" hash-object --no-filters -- "$1" 2>/dev/null \
    || printf -- '-\n'
}

# "<sha><TAB><path>" for every path on stdin.
tree_hash_rows() {
  local rel
  while IFS= read -r rel; do
    [ -n "${rel}" ] || continue
    printf '%s\t%s\n' "$(tree_hash "${rel}")" "${rel}"
  done
}

# Hashes too: ` M` before and after hides what a tool did. See docs/dependency-updates.md#how-a-change-is-seen
tree_snapshot() {
  TREE_BEFORE="$(mktemp)" || err "mktemp failed"
  TREE_BEFORE_PATHS="$(mktemp)" || err "mktemp failed"
  TREE_BEFORE_HASH="$(mktemp)" || err "mktemp failed"
  TREE_BEFORE_IGNORED="$(mktemp)" || err "mktemp failed"
  tree_status > "${TREE_BEFORE}" \
    || err "cannot read the state of ${TARGET}; nothing written"
  tree_paths < "${TREE_BEFORE}" | sort -u > "${TREE_BEFORE_PATHS}"
  tree_hash_rows < "${TREE_BEFORE_PATHS}" > "${TREE_BEFORE_HASH}"
  tree_ignored_paths > "${TREE_BEFORE_IGNORED}"
}

# The set-difference greps return 0 (no match is an answer), so unreadable input is refused here, in the main shell.
tree_readable() {
  local f
  for f in "$@"; do
    [ -r "${f}" ] || err "cannot read ${f}; the collateral guard cannot answer"
  done
}

# Already-dirty paths whose content changed.
tree_rehashed() {
  tree_hash_rows < "${TREE_BEFORE_PATHS}" \
    | grep -Fxv -f "${TREE_BEFORE_HASH}" \
    | cut -f2-
  return 0
}

# Both directions, since a deleted untracked file leaves the listing; grep, as comm/diff are not on the suites' PATH.
tree_moved_lines() {
  grep -Fxv -f "${TREE_BEFORE}" "$1"
  grep -Fxv -f "$1" "${TREE_BEFORE}"
  return 0
}

# Owned = what the rollback can put back, matched exactly (rl_has).
tree_owned() {
  rl_has "$1" ${BACKUP_PATHS[@]+"${BACKUP_PATHS[@]}"} && return 0
  rl_has "$1" ${APPLY_PATHS[@]+"${APPLY_PATHS[@]}"}
}

# Must exist in HEAD: `git diff HEAD` calls a created file unchanged. See docs/dependency-updates.md#a-rewrite-that-is-only-line-endings
tree_eol_only() {
  "${GIT_BIN}" -C "${GIT_TARGET}" cat-file -e "HEAD:$1" 2>/dev/null || return 1
  "${GIT_BIN}" -C "${GIT_TARGET}" diff --quiet --ignore-cr-at-eol HEAD -- "$1" 2>/dev/null
}

tree_verb() {
  case "$1" in
    ' D'|'D ') printf 'DELETED, and it is tracked' ;;
    ' M'|'M '|'MM') printf 'modified' ;;
    '??')      printf 'created' ;;
    'A '|'AM') printf 'created and staged' ;;
    'R'*)      printf 'renamed' ;;
    # Not a git status: tree_rehashed's bytes-changed-under-` M` finding.
    '~~')      printf 'overwritten' ;;
    # Not a git status either: tree_eol_only's finding.
    '<>')      printf 'rewritten with different LINE ENDINGS; its content is'
               printf ' unchanged' ;;
    *)         printf 'now %s' "$1" ;;
  esac
}

# Order matters: owned, then already dirty (never touched), then line-ending-only, then collateral.
tree_sort_one() {
  local pth="$1" xy="$2" verb
  tree_owned "${pth}" && return 0
  verb="$(tree_verb "${xy}")"
  # No checkout of a gitlink reaches what moved inside it, so name it as a submodule.
  [ -e "${TARGET}/${pth}/.git" ] \
    && verb="${verb}; it is a SUBMODULE, so what moved is INSIDE it and no
  checkout of this path can reach it -- git -C ${pth} status"
  if grep -Fxq -- "${pth}" "${TREE_BEFORE_PATHS}"; then
    TREE_UNSAFE+=("${pth}	${verb}; it was ALREADY changed before this run")
  elif tree_eol_only "${pth}"; then
    TREE_EOL+=("${pth}	$(tree_verb '<>')")
  else
    TREE_COLLATERAL+=("${pth}	${verb}")
  fi
}

# Once, and before any restore, which would erase its own evidence.
tree_classify() {
  [ "${TREE_CLASSIFIED}" -eq 1 ] && return 0
  [ -n "${TREE_BEFORE}" ] || return 0
  TREE_CLASSIFIED=1
  TREE_COLLATERAL=(); TREE_UNSAFE=(); TREE_EOL=()
  local now line pth seen
  now="$(mktemp)" || err "mktemp failed"
  seen="$(mktemp)" || err "mktemp failed"
  tree_status > "${now}"
  tree_readable "${TREE_BEFORE}" "${TREE_BEFORE_PATHS}" "${TREE_BEFORE_HASH}" "${now}"
  # `seen` holds exact lines, never a substring-tested string.
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    while IFS= read -r pth; do
      [ -n "${pth}" ] || continue
      grep -Fxq -- "${pth}" "${seen}" && continue
      printf '%s\n' "${pth}" >> "${seen}"
      tree_sort_one "${pth}" "${line:0:2}"
    done < <(printf '%s\n' "${line}" | tree_paths)
  done < <(tree_moved_lines "${now}")
  # Then changes the letters cannot show; second, so a placed path keeps its specific verb.
  while IFS= read -r pth; do
    [ -n "${pth}" ] || continue
    grep -Fxq -- "${pth}" "${seen}" && continue
    printf '%s\n' "${pth}" >> "${seen}"
    tree_sort_one "${pth}" '~~'
  done < <(tree_rehashed)
  rm -f "${now}" "${seen}"
}

# -unormal collapses an ignored directory to one entry: affordable, but blind to deletions inside it.
tree_ignored_paths() {
  "${GIT_BIN}" -C "${GIT_TARGET}" status --porcelain=v1 -unormal \
      --ignored=traditional 2>/dev/null \
    | grep '^!! ' | tree_paths | sort -u
  return 0
}

# No copy of an ignored path is taken, so a deleted one can only be named, never restored.
tree_ignored_report() {
  [ -n "${TREE_BEFORE_IGNORED}" ] || return 0
  TREE_IGNORED_GONE=()
  local now pth
  now="$(mktemp)" || return 0
  tree_ignored_paths > "${now}"
  tree_readable "${TREE_BEFORE_IGNORED}" "${now}"
  while IFS= read -r pth; do
    [ -n "${pth}" ] || continue
    [ -e "${TARGET}/${pth}" ] && continue
    TREE_IGNORED_GONE+=("${pth}")
  done < <(grep -Fxv -f "${now}" "${TREE_BEFORE_IGNORED}")
  rm -f "${now}"
  if note_listing \
      "an ecosystem tool DELETED these .gitignore'd path(s). No commit could" \
      "have carried them, so the guard does not refuse over them -- and no copy" \
      "of them was taken either, so this run cannot put them back:" \
      -- ${TREE_IGNORED_GONE[@]+"${TREE_IGNORED_GONE[@]}"}; then
    note "Ignored paths deleted from INSIDE an ignored directory are not listed:"
    note "git collapses such a directory to one entry and this run did not look in."
  fi
}

# Watching outside the repo is not the ask; saying so is.
tree_scope_note() {
  note ""
  note "WHAT WAS WATCHED: the working tree of ${TARGET}, and nothing outside it."
  note "Every ecosystem tool also writes elsewhere -- ~/.pub-cache, ~/.cargo/registry,"
  note "more: ~/.npm, \$HOME, a sibling checkout -- and this run neither watched those nor"
  note "could undo anything it found there."
}

# `checkout HEAD --`, never `checkout --`, which restores staged tool output. See docs/dependency-updates.md#putting-it-back-and-the-one-case-where-this-tool-must-not
restore_collateral_one() {
  local row pth verb
  row="$1"
  pth="${row%%	*}"
  # The verb half only: a path spelled `lib/created.dart` was not created by this run.
  verb="${row#*	}"
  case "${verb}" in
    created*)
      if [ -d "${TARGET}/${pth}" ]; then
        TREE_STUCK+=("${pth}	a directory; not removed")
        return 0
      fi
      rm -f "${TARGET}/${pth}"
      # Unstage too, or a staged addition reads `AD`; a no-op for `??`.
      "${GIT_BIN}" -C "${GIT_TARGET}" rm -q --cached --ignore-unmatch -- "${pth}" \
        >/dev/null 2>&1 ;;
    *)
      "${GIT_BIN}" -C "${GIT_TARGET}" checkout --quiet HEAD -- "${pth}" \
        >/dev/null 2>&1 ;;
  esac
  TREE_PUTBACK+=("${pth}")
}

# One owner for both undo paths; mapfile, since an unquoted $(...) splits a path on its spaces.
report_collateral_outcome() {
  local -a unsafe=()
  mapfile -t unsafe < <(tree_row_text ${TREE_UNSAFE[@]+"${TREE_UNSAFE[@]}"})
  note_listing "an ecosystem tool had also moved these, and they were put back:" \
    -- ${TREE_PUTBACK[@]+"${TREE_PUTBACK[@]}"} || true
  if note_listing \
      "these moved too and were NOT touched: they were ALREADY carrying local" \
      "changes when the run started, so putting them back would destroy work" \
      "this run never owned. The tree is NOT as it started in these paths:" \
      -- ${unsafe[@]+"${unsafe[@]}"}; then
    note "Decide those by hand -- \`git diff -- <path>\` says what is in them."
  fi
}

# Proven back from one set difference in a file; a grep inside a pipefail pipeline would read "none" as failure.
restore_collateral() {
  [ -n "${TREE_BEFORE}" ] || return 0
  local -a rows=(${TREE_COLLATERAL[@]+"${TREE_COLLATERAL[@]}"}
                 ${TREE_EOL[@]+"${TREE_EOL[@]}"})
  [ "${#rows[@]}" -gt 0 ] || return 0
  TREE_PUTBACK=(); TREE_STUCK=()
  local row pth now still
  local -a tried=()
  for row in "${rows[@]}"; do restore_collateral_one "${row}"; done
  now="$(mktemp)" || return 0
  still="$(mktemp)" || { rm -f "${now}"; return 0; }
  tree_status > "${now}"
  tree_readable "${TREE_BEFORE}" "${now}"
  tree_moved_lines "${now}" | tree_paths | sort -u > "${still}"
  # A stuck path leaves TREE_PUTBACK, so it is never listed as both.
  tried=(${TREE_PUTBACK[@]+"${TREE_PUTBACK[@]}"})
  TREE_PUTBACK=()
  for pth in ${tried[@]+"${tried[@]}"}; do
    if grep -Fxq -- "${pth}" "${still}"; then
      TREE_STUCK+=("${pth}	still differs after being put back")
    else
      TREE_PUTBACK+=("${pth}")
    fi
  done
  rm -f "${now}" "${still}"
}

# Collateral is named and the whole run undone; deliberately no flag accepts it.
assert_no_collateral() {
  tree_classify
  local n
  n=$(( ${#TREE_COLLATERAL[@]} + ${#TREE_UNSAFE[@]} ))
  if [ "${n}" -eq 0 ]; then
    restore_eol_rewrites
    tree_ignored_report
    tree_scope_note
    return 0
  fi
  local -a coll=() unsafe=()
  mapfile -t coll < <(tree_row_text ${TREE_COLLATERAL[@]+"${TREE_COLLATERAL[@]}"})
  mapfile -t unsafe < <(tree_row_text ${TREE_UNSAFE[@]+"${TREE_UNSAFE[@]}"})
  note ""
  note "COLLATERAL: an ecosystem tool changed path(s) this run does not own."
  note "The manifest edit was audited value by value and the lockfile refresh is"
  note "expected to rewrite its lockfile -- these are neither, so no part of this"
  note "run has been reviewed against them."
  note_listing "moved, and clean before this run started:" \
    -- ${coll[@]+"${coll[@]}"} || true
  note_listing "moved, and ALREADY carrying local changes -- NOT touched:" \
    -- ${unsafe[@]+"${unsafe[@]}"} || true
  tree_ignored_report
  tree_scope_note
  undo_run "an ecosystem tool changed ${n} path(s) outside this run"
}

# Only the proof of restore makes not refusing honest, so a line-ending rewrite that will not go back refuses.
restore_eol_rewrites() {
  [ "${#TREE_EOL[@]}" -gt 0 ] || return 0
  local -a shown=()
  mapfile -t shown < <(tree_row_text "${TREE_EOL[@]}")
  restore_collateral
  note_listing \
    "an ecosystem tool rewrote these tracked path(s) with different LINE" \
    "ENDINGS and no other change -- git's own --ignore-cr-at-eol reading says" \
    "the content is identical -- so they were put back and the run continues:" \
    -- ${shown[@]+"${shown[@]}"} || true
  [ "${#TREE_STUCK[@]}" -eq 0 ] && return 0
  mapfile -t shown < <(tree_row_text "${TREE_STUCK[@]}")
  note_listing "...except these, which would NOT go back:" \
    -- ${shown[@]+"${shown[@]}"} || true
  undo_run "${#TREE_STUCK[@]} line-ending rewrite(s) could not be put back"
}

# Lock tools may rewrite an audited manifest. See docs/dependency-updates.md#the-manifest-across-the-lock-tools
manifest_record_shas() {
  MANIFEST_SHAS=()
  local rel sha
  for rel in "$@"; do
    [ -f "${TARGET}/${rel}" ] || continue
    sha="$("${GIT_BIN}" -C "${GIT_TARGET}" hash-object --no-filters -- "${rel}" 2>/dev/null)"
    MANIFEST_SHAS+=("${rel}|${sha}")
  done
}

assert_manifests_unchanged() {
  local row rel was now
  local -a moved=()
  for row in ${MANIFEST_SHAS[@]+"${MANIFEST_SHAS[@]}"}; do
    rel="${row%%|*}"; was="${row#*|}"
    now="$("${GIT_BIN}" -C "${GIT_TARGET}" hash-object --no-filters -- "${rel}" 2>/dev/null)"
    [ "${now}" = "${was}" ] && continue
    moved+=("${rel}  (audited as ${was:0:12}, now ${now:0:12})")
  done
  [ "${#moved[@]}" -gt 0 ] || return 0
  note ""
  note "a lockfile tool REWROTE a manifest this run had already audited. The"
  note "audit proved exactly one value moved; anything the tool then did to the"
  note "file is covered by nothing:"
  printf '  %s\n' "${moved[@]}"
  undo_run "a lockfile tool rewrote ${#moved[@]} audited manifest(s)"
}
