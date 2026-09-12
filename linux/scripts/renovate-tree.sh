#!/usr/bin/env bash
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# The TREE half of renovate-local.sh: which git owns this checkout, whether the
# paths this run writes are clean, and what ELSE moved while an ecosystem tool
# ran. Not standalone -- renovate-local.sh owns note()/err()/note_listing()/
# refuse_listing(), TARGET, GIT_BIN/GIT_TARGET, APPLY_PATHS and EDIT_FILES, and
# renovate-locks.sh owns BACKUP_PATHS and the undo this one joins.
# docs/dependency-updates.md#nothing-else-in-the-repo-moved
[ -n "${_RENOVATE_TREE_SH_LOADED:-}" ] && return 0
_RENOVATE_TREE_SH_LOADED=1

# What the checkout looked like before the first byte, and what the comparison
# afterwards found. TREE_BEFORE holds git's porcelain lines; TREE_BEFORE_PATHS
# the paths out of them, one per line, so "was this path ALREADY dirty" is an
# exact line match rather than a substring guess; TREE_BEFORE_IGNORED the
# .gitignore'd paths, which no commit can carry and which a human can still
# LOSE -- see tree_ignored_report.
TREE_BEFORE=""; TREE_BEFORE_PATHS=""; TREE_BEFORE_HASH=""; TREE_BEFORE_IGNORED=""
TREE_CLASSIFIED=0
# Every row below is "<path><TAB><what happened to it>", rendered for a human by
# tree_row_text. A TAB and not the rendered "<path>  (verb)" text, because
# restore_collateral_one has to get the PATH back out of a row: splitting that
# text on "  (" is a restore aimed at the wrong file the moment a path legally
# contains two spaces and a bracket.
TREE_COLLATERAL=()   # moved, this run does not own it, and it was clean before
TREE_UNSAFE=()       # moved, and it was ALREADY dirty -- not ours to put back
TREE_EOL=()          # moved, tracked, and the ONLY difference is line endings
TREE_PUTBACK=()      # collateral proven back where it was
TREE_STUCK=()        # collateral that would not go back
TREE_IGNORED_GONE=() # ignored paths a tool DELETED; no copy of them was taken

# The manifests' blob shas the moment the audited edit landed. The lock tools
# run AFTER that, in the manifest's own directory, and several of them
# (`flutter pub get`, `npm install`) rewrite the manifest they are handed.
MANIFEST_SHAS=()

# --------------------------------------------------------------------------
# Is the tree clean enough to write? (moved here from renovate-local.sh, which
# was over the 800-line file limit once the fix below was commented honestly)
# --------------------------------------------------------------------------

# Genuinely dirty, or merely read by the wrong git? --ignore-cr-at-eol separates
# them. --ignore-submodules=dirty is the SECOND half of that separation and
# ignores nothing this run writes: a dirty NESTED submodule makes its parent's
# gitlink read `<sha>` / `<sha>-dirty` -- the SAME sha -- and no end-of-line
# option can reach it. `dirty`, never `all`, and BOTH questions take it. The
# five measured directions and the (H1)-(H4) cases that pin them:
# docs/dependency-updates.md#the-nested-submodule-that-no-end-of-line-option-can-reach
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

# Every path this run would write: a submodule's own working tree, and each
# manifest about to be edited. Both are asked the same two questions.
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

# The two halves of this script need DIFFERENT gits on the documented Windows
# workflow: the report needs node, which lives in WSL, while the checkout needs the
# git that WROTE the working tree. WSL can call the Windows git, so switch to it
# rather than refusing.
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

# THE COLLATERAL GUARD. renovate_audit.py proves "exactly one value changed IN
# THIS FILE"; nothing proved "and nothing else in the REPO changed", and an
# ecosystem tool DELETED three tracked translation files during a run about
# permission_handler. EXPECTED is exactly the ROLLBACK'S OWN REACH --
# BACKUP_PATHS (manifests and their lockfiles) plus APPLY_PATHS (the gitlinks);
# everything else git reports as moved is COLLATERAL, except what .gitignore
# covers, which cannot reach a commit. The incident and the contract:
# docs/dependency-updates.md#nothing-else-in-the-repo-moved

# git's OWN view of the whole checkout, one porcelain line per entry. `status`
# and not `diff`: a file an ecosystem tool CREATES has to be as visible as one it
# deletes, and only status shows both. -uall so a file added inside a directory
# that was already untracked gets a line of its own -- git does not walk into
# IGNORED directories to produce it, so the cost is the size of the tree's
# untracked-but-committable content, which is small in a healthy repo (measured
# on OmniAccelerANT over /mnt/d: 4.2s, the same as the collapsed form, i.e. the
# filesystem rather than the flag).
#
# NO --ignore-submodules HERE, and that is the OPPOSITE of classify_one above.
# THE TENSION, resolved: one flag, two callers, two different questions.
#   classify_one asks "is the HUMAN'S tree clean enough to write into", which is
#     an ABSOLUTE reading, and a dirty NESTED submodule makes its parent's
#     gitlink read `<sha>-dirty` against the SAME sha for a reason that is none
#     of this run's business -- so it takes `dirty` ((H1)-(H4)).
#   tree_status asks "what did the ecosystem TOOL touch", which is a DIFFERENTIAL
#     reading: the same snapshot is taken before and after and only the change
#     between them counts. A nested submodule that read `-dirty` before still
#     reads `-dirty` after, so it produces the same porcelain line twice and
#     cancels -- the flag buys nothing here and costs everything.
# What it costs: MEASURED 2026-09-11 -- a lock tool deleted a TRACKED file and
# created an untracked one INSIDE a submodule, and with the flag the whole run
# exited 0 having reported nothing. Not hypothetical on this family's flagship:
# OmniAccelerANT's pubspec declares `anthology: path: third_party/ANThology`,
# that path IS a submodule, and a superproject .gitignore does not apply inside
# one. docs/dependency-updates.md#the-same-flag-two-questions
tree_status() {
  "${GIT_BIN}" -C "${GIT_TARGET}" status --porcelain=v1 -uall 2>/dev/null
}

# git's own spelling of a path that needs quoting: the whole path in double
# quotes, with \\ \" \a \b \f \n \r \t \v and \NNN octal for every other byte
# (core.quotePath). MEASURED: a plain SPACE is enough -- ` M "app one/pubspec.yaml"`.
# Undoing it is not cosmetic. The quoted spelling never equals the plain path in
# BACKUP_PATHS, so BOTH directions were wrong at once: a run editing
# `app one/pubspec.yaml` refused over its OWN manifest, and the two tracked
# files the tool really deleted were never named (measured 2026-09-11).
# The two octal rewrites come first, and \\ before \", so the second pass cannot
# read the backslash of an escaped backslash as the start of an escape.
tree_unquote() {
  local s="$1"
  case "${s}" in '"'*'"') ;; *) printf '%s\n' "${s}"; return 0 ;; esac
  s="${s#\"}"; s="${s%\"}"
  s="${s//\\\\/\\0134}"
  s="${s//\\\"/\\0042}"
  printf '%b\n' "${s}"
}

# One path, unquoted -- except a path carrying a NEWLINE, which is the one shape
# a line-per-path comparison cannot hold. That one keeps its quoted spelling, so
# it stays a single line, matches nothing this run owns, and lands on the
# REFUSING side of the guard. Stated rather than papered over.
tree_emit_path() {
  case "$1" in *'\n'*) printf '%s\n' "$1"; return 0 ;; esac
  tree_unquote "$1"
}

# The path(s) out of porcelain lines on stdin. `R  old -> new` names two, and
# both matter; every other status names one.
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

# The bytes at one repo-relative path, or "-" for a path with no regular file at
# it. git hash-object rather than a checksum tool: git is the one binary this
# half is guaranteed, and --no-filters makes it a hash of the bytes on disk, so
# nothing rides on the checkout's line-ending setting.
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

# How the tree stands before the first byte. THREE files, because the classifier
# asks three questions: which porcelain LINES it had (did this path move?),
# which PATHS it had (was this one already dirty, i.e. not ours to put back?),
# and what those already-dirty ones CONTAINED -- because a path that was ` M`
# before and is ` M` after produces the SAME line whatever the tool did to it,
# which is why (K3) was red until the hashes were taken.
# docs/dependency-updates.md#how-a-change-is-seen
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

# THE ONE RULE THE THREE SET DIFFERENCES BELOW SHARE, and the reason they are
# written out rather than inlined: `grep -Fxv -f A B` exits 1 when it selects NO
# LINES, and "no line was selected" is the ANSWER here, not a failure. Under
# this file's `set -uo pipefail` that 1 propagated out of a pipeline and made
# restore_collateral's proof-of-restore dead code -- for MONTHS the run printed
# "they were put back" over a file that was still deleted (measured
# deterministic 10/10, 2026-09-11). So each ends with an explicit `return 0`,
# and NOT with a `|| true` at the call site: the fact belongs to the function.
# The 2>/dev/null those greps used to carry is gone with it -- a grep that
# cannot READ its input is a real failure and must not be silent. It cannot be
# CAUGHT there either: every one of these runs inside a pipeline or a process
# substitution, where err() would end the subshell and hand the caller a
# truncated answer to read as if it were the whole one. So the one failure they
# can actually have is ruled out first, in the main shell, where a refusal is
# still possible.
tree_readable() {
  local f
  for f in "$@"; do
    [ -r "${f}" ] || err "cannot read ${f}; the collateral guard cannot answer"
  done
}

# The already-dirty paths whose CONTENT is not what it was, over
# "<sha><TAB><path>" rows.
tree_rehashed() {
  tree_hash_rows < "${TREE_BEFORE_PATHS}" \
    | grep -Fxv -f "${TREE_BEFORE_HASH}" \
    | cut -f2-
  return 0
}

# Every porcelain line in one snapshot and not the other, BOTH directions. An
# untracked file a tool deletes LEAVES the listing rather than joining it, and
# losing a human's uncommitted file is exactly the collateral this is for.
# grep -Fxv -f rather than comm or diff: neither is on the suites' PATH, and a
# tool this list depends on is a tool the fixture has to grow.
tree_moved_lines() {
  grep -Fxv -f "${TREE_BEFORE}" "$1"
  grep -Fxv -f "$1" "${TREE_BEFORE}"
  return 0
}

# EXPECTED is exactly what the rollback can put back. BACKUP_PATHS is the
# manifests and the lockfiles; APPLY_PATHS the gitlinks.
# An EXACT match, element by element, through rl_has -- which is where the
# argument for exactness lives. It was a SUBSTRING test over a space-joined
# list, so with BACKUP_PATHS holding 'app one/pubspec.yaml' both `app` and
# `one/pubspec.yaml` read as OWNED, and a tool that deleted two tracked files of
# exactly those names was never reported and never undone (measured 2026-09-11).
tree_owned() {
  rl_has "$1" ${BACKUP_PATHS[@]+"${BACKUP_PATHS[@]}"} && return 0
  rl_has "$1" ${APPLY_PATHS[@]+"${APPLY_PATHS[@]}"}
}

# Tracked, and the ONLY thing that differs from HEAD is the end-of-line bytes.
# THE DECIDING CASE, measured 2026-09-11 with the real toolchain in the family
# Windows CI image (`linux/scripts/ci-image-ref.sh --windows`) over a copy of
# OmniAccelerANT: `flutter pub get` -- which `flutter: generate: true` plus
# l10n.yaml makes regenerate lib/l10n/app_localizations{,_de,_en}.dart, all
# three TRACKED -- rewrote all three, LF over a CRLF checkout. Per file:
#   git status --porcelain          ->  M   (so the guard SEES them)
#   git diff --quiet HEAD           ->  1   (the bytes really did change)
#   git diff --quiet --ignore-cr-at-eol HEAD -> 0
#   byte proof: identical once CR is removed
# and pubspec.lock, which this run DOES own, came back 1 from the same
# --ignore-cr-at-eol reading -- so the test separates the two cleanly.
# Left as plain collateral that refuses, the guard would refuse every pub update
# on this repo forever over a difference that is not one. So such a path is
# NAMED, PUT BACK from HEAD, and PROVEN back -- and only then not refused. It is
# the same reading of the same flag classify_one already makes about the same
# question. A path git does not have in HEAD is never eligible: `git diff HEAD`
# says "no difference" about a file HEAD never had, which would read every
# CREATED file as end-of-line noise.
tree_eol_only() {
  "${GIT_BIN}" -C "${GIT_TARGET}" cat-file -e "HEAD:$1" 2>/dev/null || return 1
  "${GIT_BIN}" -C "${GIT_TARGET}" diff --quiet --ignore-cr-at-eol HEAD -- "$1" 2>/dev/null
}

# What git's two status letters mean, spelled for a human who is being told a
# file they did not ask about has moved.
tree_verb() {
  case "$1" in
    ' D'|'D ') printf 'DELETED, and it is tracked' ;;
    ' M'|'M '|'MM') printf 'modified' ;;
    '??')      printf 'created' ;;
    'A '|'AM') printf 'created and staged' ;;
    'R'*)      printf 'renamed' ;;
    # Not a git status: tree_rehashed's finding, which git's two letters cannot
    # express -- a path that reads ` M` both before and after while its BYTES
    # changed underneath.
    '~~')      printf 'overwritten' ;;
    # Not a git status either: tree_eol_only's finding.
    '<>')      printf 'rewritten with different LINE ENDINGS; its content is'
               printf ' unchanged' ;;
    *)         printf 'now %s' "$1" ;;
  esac
}

# One moved path, sorted into the list that decides what happens to it. Order
# matters: owned first, then ALREADY dirty (which this tool must not touch
# whatever else is true of it), then end-of-line-only, then collateral.
tree_sort_one() {
  local pth="$1" xy="$2" verb
  tree_owned "${pth}" && return 0
  verb="$(tree_verb "${xy}")"
  # A gitlink says ` M` for anything at all inside it, and `checkout HEAD --` on
  # one is a no-op the proof-of-restore then reports as stuck. Saying WHICH kind
  # of path it is turns that report into something a human can act on.
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

# Everything that moved and is not this run's, worked out ONCE. It has to run
# before a single byte goes back, or the restore erases its own evidence -- which
# is why restore_targets calls it first rather than trusting a caller to.
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
  # `seen` is a FILE of exact lines, not a space-joined string: the substring
  # test it replaces called `app` seen once `app one/pubspec.yaml` had been,
  # which is the same defect tree_owned carried.
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    while IFS= read -r pth; do
      [ -n "${pth}" ] || continue
      grep -Fxq -- "${pth}" "${seen}" && continue
      printf '%s\n' "${pth}" >> "${seen}"
      tree_sort_one "${pth}" "${line:0:2}"
    done < <(printf '%s\n' "${line}" | tree_paths)
  done < <(tree_moved_lines "${now}")
  # ...and the paths git's two letters cannot report a change on, because they
  # were already listed under the same letters before the run. Second, so that
  # a path the line diff already placed keeps its more specific verb.
  while IFS= read -r pth; do
    [ -n "${pth}" ] || continue
    grep -Fxq -- "${pth}" "${seen}" && continue
    printf '%s\n' "${pth}" >> "${seen}"
    tree_sort_one "${pth}" '~~'
  done < <(tree_rehashed)
  rm -f "${now}" "${seen}"
}

# The .gitignore'd paths of this checkout, one per line. `-unormal` and not
# `-uall` on purpose: it collapses an ignored DIRECTORY to one entry while still
# naming an ignored FILE individually, which is the shape that makes the
# comparison below affordable AND is exactly the resolution it can honestly
# claim -- a file deleted from INSIDE an ignored directory is not visible here,
# and an ignored directory is a cache directory by construction.
tree_ignored_paths() {
  "${GIT_BIN}" -C "${GIT_TARGET}" status --porcelain=v1 -unormal \
      --ignored=traditional 2>/dev/null \
    | grep '^!! ' | tree_paths | sort -u
  return 0
}

# What .gitignore covered and is now GONE. The contract's argument -- that no
# commit can carry an ignored path -- is about COMMITTABILITY, and a human who
# loses `secrets.env` to a lock tool has still lost it: measured 2026-09-11, the
# file was deleted, never named, and the run printed that everything had been
# put back. Nothing here can undo it, because no copy of an ignored path is
# taken; what it can do is say so, on the passing path as well as the refusing
# one. It costs one extra collapsed status walk per --apply, which is why it is
# not also asked in report mode, where nothing writes.
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

# What this guard watched, and what it did not. Printed by every --apply that
# gets as far as running an ecosystem tool, passing or refusing. Measured
# 2026-09-11: a lock tool deleted a file in a SIBLING directory, created another
# there, and wrote into $HOME, and the run said not one word about any of it --
# then closed with "Nothing is staged or committed. Stage the paths you
# reviewed", which a human reading it after an undo message will over-read.
# Watching outside the repo is not the ask. Saying so is.
tree_scope_note() {
  note ""
  note "WHAT WAS WATCHED: the working tree of ${TARGET}, and nothing outside it."
  note "Every ecosystem tool also writes elsewhere -- ~/.pub-cache, ~/.cargo/registry,"
  note "more: ~/.npm, \$HOME, a sibling checkout -- and this run neither watched those nor"
  note "could undo anything it found there."
}

# Putting collateral back, and the one case where this tool must NOT.
# A path CLEAN before the run is put back with git -- tracked ones checked out,
# ones the tool CREATED removed -- because git holds the bytes and no copy was
# taken. A path ALREADY dirty is not touched at all: the human's own work is in
# it and `git checkout` would destroy the very thing the pre-flight refuses to
# write over. That is the one state where "exactly as it started" is unavailable.
#
# `checkout HEAD --`, never `checkout --`. The latter restores from the INDEX,
# so any tool that STAGES what it did defeated the undo completely, and both
# shapes were measured on 2026-09-11:
#   a staged DELETION  -> `checkout --` exits 1 "pathspec did not match", the
#                         file stays GONE, status `D  lib/gen.dart`
#   a staged MODIFICATION -> `checkout --` is a NO-OP, the file keeps the bytes
#                         the TOOL wrote, status `M  lib/gen.dart`
# and in both the run then printed that it had been put back. That is the l10n
# incident shape exactly. `HEAD` rewrites the index as well as the working tree
# (measured: status clean afterwards), so it unstages in the same move.
# docs/dependency-updates.md#putting-it-back-and-the-one-case-where-this-tool-must-not
restore_collateral_one() {
  local row pth verb
  row="$1"
  pth="${row%%	*}"
  # The VERB half, never the whole row: a path spelled `lib/created.dart` is not
  # a file this run created.
  verb="${row#*	}"
  case "${verb}" in
    created*)
      if [ -d "${TARGET}/${pth}" ]; then
        TREE_STUCK+=("${pth}	a directory; not removed")
        return 0
      fi
      rm -f "${TARGET}/${pth}"
      # ...and out of the INDEX, for the `A ` half of "created": a file removed
      # from disk while its addition is still staged reads `AD`, which is not
      # "as it started" by any reading. --ignore-unmatch makes this a no-op for
      # the `??` half, which was never in the index at all.
      "${GIT_BIN}" -C "${GIT_TARGET}" rm -q --cached --ignore-unmatch -- "${pth}" \
        >/dev/null 2>&1 ;;
    *)
      "${GIT_BIN}" -C "${GIT_TARGET}" checkout --quiet HEAD -- "${pth}" \
        >/dev/null 2>&1 ;;
  esac
  TREE_PUTBACK+=("${pth}")
}

# What happened to the collateral, printed by BOTH undo paths -- the one a
# failing tool takes and the one a signal takes. One owner because the two had
# grown the same pair of listings with different wording, which is two contracts
# for one fact, and the duplication gate caught the second copy.
# mapfile and not `-- $(tree_row_text ...)`: an unquoted command substitution
# splits on every space, which is how a path with a space in it becomes two
# items in a listing that exists to name paths exactly.
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

# The rows handed to restore_collateral_one, then PROVEN back: the same
# comparison is run again afterwards, and a path still moved joins TREE_STUCK,
# which restore_targets folds into RESTORE_FAILED so the copies beside the run
# are kept rather than deleted over a restore nobody checked.
#
# The proof used to be `if tree_moved_lines ... | grep -Fxq -- "${pth}"` inline,
# and under `set -uo pipefail` it was DEAD: tree_moved_lines ends with a grep
# that exits 1 whenever no porcelain line DISAPPEARED, which is the normal case
# and ALWAYS the case over a tree that was clean, so the pipeline was false for
# every path and TREE_STUCK was never filled. The set difference is now taken
# ONCE into a file -- also one status comparison instead of one per path -- and
# the grep that reads it stands alone, where its 1 means what it says.
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
  # A path that would not go back leaves TREE_PUTBACK rather than joining
  # TREE_STUCK as well. Standing under BOTH headings -- "they were put back" and
  # "these could NOT be put back" -- is the same lie the proof was added to end,
  # just printed twice.
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

# The refusal. It runs after BOTH halves are done and before the run settles, so
# what it claims is about the whole run: the manifests moved, their lockfiles were
# refreshed, the gitlinks moved, and nothing else in the repo did.
#
# THE CONTRACT, argued in docs/dependency-updates.md#nothing-else-in-the-repo-moved:
# collateral is neither silently kept nor silently reverted. It is NAMED, the
# whole run is undone -- manifests, lockfiles and gitlinks, the rc 1 contract that
# already existed -- and the run FAILS. There is deliberately no flag to accept
# it: "apply the update anyway and let the human notice the three deleted
# translation files" is precisely the tolerated failure this tree refuses.
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

# The end-of-line-only rewrites, on a run with nothing to refuse over. They are
# put back like any other collateral and PROVEN back -- and only the proof is
# what makes not refusing honest, so a path that will not go back refuses after
# all. See tree_eol_only for the measurement this whole arm exists for.
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

# --------------------------------------------------------------------------
# The manifest, across the lock tools. The audit proves one value changed the
# moment the edit lands; the lock tools then run in that same directory and
# several of them rewrite the manifest they are handed, AFTER the proof and
# covered by nothing. So the bytes are hashed between the two and compared.
# docs/dependency-updates.md#the-manifest-across-the-lock-tools
# --------------------------------------------------------------------------
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
