#!/usr/bin/env bash
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# The lockfile half of renovate-local.sh, sourced by it. See docs/dependency-updates.md#the-gitlink-half-is-part-of-the-unit
[ -n "${_RENOVATE_LOCKS_SH_LOADED:-}" ] && return 0
_RENOVATE_LOCKS_SH_LOADED=1

# LOCK_JOBS: one "<manager>|<file>|<dep>|<declared>" per manifest an EDIT touches, or per maintained lock.
LOCK_JOBS=(); LOCK_MISSING=(); LOCK_PLANNED=(); LOCK_DONE=()

# The dep of a lock file maintenance job: every entry moves (renovate_planner.py LOCK_ALL).
LOCK_ALL='*'

# The job for_each_lock is on, for a callback that must keep it (renovate-local.sh maint_plan_one).
LOCK_JOB_NOW=""
LOCK_AMBIGUOUS=(); LOCK_FAILED=""
BACKUP_DIR=""; BACKUP_PATHS=(); RESTORE_FAILED=()

# ""|taken|applied|restored|stuck: what the copies are worth now, the only thing letting discard_backups() delete them.
BACKUP_STATE=""

# "<path>\t<sha>\t<ref>" per submodule; the ref restores the attachment --remote detaches. See docs/dependency-updates.md#the-gitlink-half-is-part-of-the-unit
BACKUP_LINKS=()

# A kill cannot be trapped, so this marker makes the next run refuse instead (write_inflight, assert_no_wreckage).
INFLIGHT_MARK=""

# Which lock, and whose: a missing lock tool refuses the run before anything is written.

# Every lock this manager can own; the tree picks the real one. Stdout is the answer, so nothing may log to it.
lock_kinds() {
  local mgr="$1" file="$2"
  case "${mgr}" in
    cargo)  printf '%s\n' 'Cargo.lock cargo' ;;
    pep621) printf '%s\n' 'uv.lock uv' 'poetry.lock poetry' 'pdm.lock pdm' ;;
    npm)    printf '%s\n' 'package-lock.json npm' 'yarn.lock yarn' 'pnpm-lock.yaml pnpm' ;;
    pub)    if grep -q '^[[:space:]]*flutter[[:space:]]*:' "${TARGET}/${file}" 2>/dev/null; then
              printf '%s\n' 'pubspec.lock flutter'
            else
              printf '%s\n' 'pubspec.lock dart'
            fi ;;
  esac
}

# One owner: `./Cargo.lock` in a message and `Cargo.lock` in an assertion are different strings.
rl_join() { if [ "$1" = "." ]; then printf '%s' "$2"; else printf '%s/%s' "$1" "$2"; fi; }

# Exact membership; a substring test over a space-joined list breaks on elements with spaces.
rl_has() {
  local needle="$1" q
  shift
  for q in "$@"; do [ "${q}" = "${needle}" ] && return 0; done
  return 1
}

# Only an ancestor that declares a workspace owns a member's lock. See docs/dependency-updates.md#a-workspace-members-lock-is-at-the-root
lock_workspace_root() {
  local mgr="$1" d="$2" f pat p
  case "${mgr}" in
    cargo)  f=Cargo.toml;     pat='^\[workspace\]' ;;
    npm)    f=package.json;   pat='"workspaces"[[:space:]]*:' ;;
    pub)    f=pubspec.yaml;   pat='^workspace[[:space:]]*:' ;;
    pep621) f=pyproject.toml; pat='^\[tool\.uv\.workspace\]' ;;
    *) return 1 ;;
  esac
  while [ "${d}" != "." ]; do
    d="$(dirname "${d}")"
    p="${TARGET}/$(rl_join "${d}" "${f}")"
    [ -f "${p}" ] && grep -qE -- "${pat}" "${p}" && { printf '%s\n' "${d}"; return 0; }
  done
  return 1
}

# Every "<lockfile> <tool>" this manager could own that EXISTS in <dir>.
lock_have_in() {
  local mgr="$1" file="$2" dir="$3" lock tool
  while read -r lock tool; do
    [ -n "${lock}" ] || continue
    [ -f "${TARGET}/$(rl_join "${dir}" "${lock}")" ] && printf '%s %s %s\n' "${lock}" "${tool}" "${dir}"
  done < <(lock_kinds "${mgr}" "${file}")
  return 0
}

# "<lockfile> <tool> <dir>" lines, dir last as it may hold spaces; rc 1 none, rc 2 several (the caller refuses).
lock_target() {
  local mgr="$1" file="$2" dir root
  local -a have=()
  dir="$(dirname "${file}")"
  mapfile -t have < <(lock_have_in "${mgr}" "${file}" "${dir}")
  if [ "${#have[@]}" -eq 0 ] && root="$(lock_workspace_root "${mgr}" "${dir}")"; then
    mapfile -t have < <(lock_have_in "${mgr}" "${file}" "${root}")
  fi
  [ "${#have[@]}" -gt 0 ] || return 1
  printf '%s\n' "${have[@]}"
  [ "${#have[@]}" -eq 1 ] || return 2
  return 0
}

# The lockfile names out of lock_target's output, on one line for a message.
lock_names() {
  local lock tool out=""
  while read -r lock tool; do
    [ -n "${lock}" ] || continue
    out="${out:+${out}, }${lock}"
  done <<<"$1"
  printf '%s\n' "${out}"
}

# The lock's own directory, which for a workspace member is not the manifest's.
lock_label() { rl_join "$1" "$2"; printf '\n'; }

# `name@<partial version>`, never a requirement like =2.12.0; it disambiguates a crate the lock holds twice.
cargo_spec() {
  local dep="$1" cur="${2:-}" v
  v="${cur//[ =^~<>]/}"
  case "${v}" in
    ""|*[!0-9.]*) printf '%s' "${dep}" ;;
    *) printf '%s@%s' "${dep}" "${v}" ;;
  esac
}

# Retry with the bare name: an earlier job in this run may already have moved the crate past the spec.
run_cargo_lock() {
  local dir="$1" dep="$2" cur="$3" spec
  spec="$(cargo_spec "${dep}" "${cur}")"
  ( cd "${dir}" && cargo update -p "${spec}" ) && return 0
  [ "${spec}" = "${dep}" ] && return 1
  ( cd "${dir}" && cargo update -p "${dep}" )
}

# Renovate's own lockFileMaintenance command per tool (its manager artifacts), one argv word per line; rc 1 = none known.
maint_argv() {
  case "$1" in
    cargo)        printf '%s\n' cargo update ;;
    dart|flutter) printf '%s\n' "$1" pub upgrade ;;
    uv)           printf '%s\n' uv lock --upgrade ;;
    poetry)       printf '%s\n' poetry update --lock ;;
    pdm)          printf '%s\n' pdm update --no-sync --update-eager ;;
    npm)          printf '%s\n' npm update --package-lock-only --ignore-scripts ;;
    pnpm)         printf '%s\n' pnpm update --lockfile-only ;;
    *)            return 1 ;;
  esac
}

# Run in the lockfile's directory (npm in a member dir writes a second lock); an unknown tool is an error.
run_lock_tool() {
  local tool="$1" dir="$2" dep="$3" cur="$4"
  local -a argv=()
  if [ "${dep}" = "${LOCK_ALL}" ]; then
    # A failure here is LOCK_FAILED, so the undo runs; plan_lock_maintenance keeps unknown tools out anyway.
    mapfile -t argv < <(maint_argv "${tool}")
    [ "${#argv[@]}" -gt 0 ] || return 1
    ( cd "${dir}" && "${argv[@]}" )
    return $?
  fi
  case "${tool}" in
    cargo)        run_cargo_lock "${dir}" "${dep}" "${cur}"; return $? ;;
    dart|flutter) argv=("${tool}" pub get) ;;
    uv)           argv=(uv lock) ;;
    poetry)       argv=(poetry lock) ;;
    pdm)          argv=(pdm lock) ;;
    npm)          argv=(npm install --package-lock-only --ignore-scripts) ;;
    yarn)         argv=(yarn install --mode update-lockfile) ;;
    pnpm)         argv=(pnpm install --lockfile-only) ;;
    *)            err "no lockfile command known for ${tool}" ;;
  esac
  ( cd "${dir}" && "${argv[@]}" )
}

# One walk for all four consumers; a manifest beside several lockfiles lands in LOCK_AMBIGUOUS instead.
for_each_lock() {
  local fn="$1" job mgr file dep cur found rc lock tool dir
  LOCK_AMBIGUOUS=()
  for job in ${LOCK_JOBS[@]+"${LOCK_JOBS[@]}"}; do
    IFS='|' read -r mgr file dep cur <<<"${job}"
    found="$(lock_target "${mgr}" "${file}")"
    rc=$?
    if [ "${rc}" -eq 1 ]; then
      continue
    fi
    if [ "${rc}" -eq 2 ]; then
      LOCK_AMBIGUOUS+=("${file} sits beside $(lock_names "${found}")")
      continue
    fi
    IFS=' ' read -r lock tool dir <<<"${found}"
    # shellcheck disable=SC2034  # read by the callback, renovate-local.sh maint_plan_one
    LOCK_JOB_NOW="${job}"
    "${fn}" "${tool}" "${dep}" "${dir}" "$(lock_label "${dir}" "${lock}")" "${cur}"
  done
}

# The consumers of that walk. Args: <tool> <dep> <dir> <label> <value>.
lock_missing_one() {
  if ! command -v "$1" >/dev/null 2>&1; then
    LOCK_MISSING+=("$4 needs '$1', which is not on this PATH")
  fi
}

lock_planned_one() {
  if [ "$2" = "${LOCK_ALL}" ]; then
    LOCK_PLANNED+=("$4 via $(maint_argv "$1" | tr '\n' ' ')(lock file maintenance)")
  else
    LOCK_PLANNED+=("$4 via $1")
  fi
}

# Records a failure instead of exiting: the manifests are written, so undo_run must restore the whole set.
lock_refresh_one() {
  if [ -n "${LOCK_FAILED}" ]; then return 0; fi
  note "  $4 via $1"
  if ! run_lock_tool "$1" "${TARGET}/$3" "$2" "$5"; then
    LOCK_FAILED="'$1' could not refresh $4"
    return 0
  fi
  LOCK_DONE+=("$4")
}

# $4, the label, is already the repo-relative path.
lock_backup_one() { backup_one "$4"; }

# Checked while the tree is untouched: a missing or ambiguous lock tool refuses the run.
assert_locks_runnable() {
  LOCK_MISSING=()
  for_each_lock lock_missing_one
  refuse_listing "ambiguous lockfile(s) -- see the list above" \
    "Remove the lockfile(s) that do not belong to this project, or scope the
run away from that ecosystem with --managers <csv>." \
    "REFUSING to apply: a manifest this run would edit sits beside SEVERAL" \
    "lockfiles, and which tool owns it is not knowable from the tree. Picking" \
    "one is how a lock goes stale behind a green run, so nothing is written:" \
    -- ${LOCK_AMBIGUOUS[@]+"${LOCK_AMBIGUOUS[@]}"}
  refuse_listing "lockfile tool(s) missing -- see the list above" \
    "Install the named tool(s) and re-run, or scope the run away from that
ecosystem with --managers <csv>." \
    "REFUSING to apply: a manifest this run would edit has a lockfile, and the" \
    "tool that owns it is missing. An edited manifest beside a stale lock is" \
    "worse than an unedited one, so nothing is written:" \
    -- ${LOCK_MISSING[@]+"${LOCK_MISSING[@]}"}
  # Probed now, so the same failure after the tool ran means the tool broke it.
  lock_probe_all
  refuse_listing "unreadable lockfile(s) -- see the list above" \
    "Fix or regenerate the lockfile with its own tool, then re-run." \
    "REFUSING to apply: a lockfile this run would refresh cannot be read by the" \
    "real parser for its format BEFORE anything is written. Editing a manifest" \
    "beside a lockfile nobody can parse is not an update, it is a second" \
    "problem stacked on the first:" \
    -- ${LOCK_UNREADABLE[@]+"${LOCK_UNREADABLE[@]}"}
}

# Lockfiles are rewritten wholesale. See docs/dependency-updates.md#what-can-be-said-about-a-lockfile
LOCK_UNREADABLE=(); LOCK_SAID=()

# Unreadable before the first byte is the tree's problem (refuse); after, the tool's (undo).
lock_probe_one() {
  local out rc
  out="$(rl_py lockcheck "${TARGET}" "$4" "$2" 2>&1)"
  rc=$?
  if [ "${rc}" -ne 0 ]; then LOCK_UNREADABLE+=("${out}"); else LOCK_SAID+=("${out}"); fi
}

lock_probe_all() {
  LOCK_UNREADABLE=(); LOCK_SAID=()
  for_each_lock lock_probe_one
}

assert_locks_sane() {
  [ "${#LOCK_DONE[@]}" -gt 0 ] || return 0
  lock_probe_all
  note ""
  note "what can be said about the refreshed lockfile(s) -- a lockfile is"
  note "rewritten wholesale, so this is a narrower claim than the manifest audit:"
  if [ "${#LOCK_SAID[@]}" -gt 0 ]; then printf '%s\n' "${LOCK_SAID[@]}"; fi
  [ "${#LOCK_UNREADABLE[@]}" -gt 0 ] || return 0
  note ""
  note "a lockfile this run refreshed cannot be read back. The SAME reading was"
  note "taken before anything was written and passed, so this is what the tool"
  note "did to it:"
  printf '%s\n' "${LOCK_UNREADABLE[@]}"
  undo_run "${#LOCK_UNREADABLE[@]} refreshed lockfile(s) cannot be read back"
}

refresh_locks() {
  [ "${#LOCK_JOBS[@]}" -gt 0 ] || return 0
  note ""
  note "refreshing the lockfile(s) the edits made stale, and any under lock file maintenance:"
  LOCK_DONE=()
  LOCK_FAILED=""
  for_each_lock lock_refresh_one
  if [ "${#LOCK_DONE[@]}" -eq 0 ] && [ -z "${LOCK_FAILED}" ]; then
    note "  (none of the edited manifests has a lockfile in this tree)"
  fi
}

# The undo: a pre-flight cannot prove a lock tool succeeds. See docs/dependency-updates.md#all-of-it-or-none-of-it
backup_one() {
  local rel="$1" n
  rl_has "${rel}" ${BACKUP_PATHS[@]+"${BACKUP_PATHS[@]}"} && return 0
  [ -f "${TARGET}/${rel}" ] || return 0
  n="${#BACKUP_PATHS[@]}"
  cp -p "${TARGET}/${rel}" "${BACKUP_DIR}/${n}" \
    || err "cannot copy ${rel} aside before writing it; nothing written"
  # On disk at once: after a kill, a copy nobody can place is not a backup.
  printf '%s\t%s\n' "${n}" "${rel}" >> "${BACKUP_DIR}/MANIFEST" \
    || err "cannot record ${rel} in ${BACKUP_DIR}/MANIFEST; nothing written"
  BACKUP_PATHS+=("${rel}")
}

# The submodule's own HEAD, not `HEAD:<path>`: `--remote` moves its working tree, not the index.
snapshot_gitlinks() {
  local pth sha ref
  BACKUP_LINKS=()
  for pth in "$@"; do
    if [ ! -e "${TARGET}/${pth}/.git" ]; then
      BACKUP_LINKS+=("$(printf '%s\t-\t-' "${pth}")")
      continue
    fi
    sha="$("${GIT_BIN}" -C "${GIT_TARGET}/${pth}" rev-parse HEAD 2>/dev/null)" \
      || err "cannot read the current commit of submodule ${pth}; nothing written"
    ref="$("${GIT_BIN}" -C "${GIT_TARGET}/${pth}" symbolic-ref --quiet HEAD 2>/dev/null || true)"
    BACKUP_LINKS+=("$(printf '%s\t%s\t%s' "${pth}" "${sha}" "${ref}")")
  done
}

# In the target's git dir: per checkout, never committed, found by the next run whatever its TMPDIR.
inflight_path() {
  local gd
  gd="$(git -C "${TARGET}" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  printf '%s/renovate-local-inflight\n' "${gd}"
}

# An explicit "(none)": a blank line under a heading reads as the tool forgetting to say.
inflight_list() {
  if [ "$#" -eq 0 ]; then printf '  (none)\n'; else printf '  %s\n' "$@"; fi
}

# Written before the first byte and self-contained: the process that knew the rest may be dead.
write_inflight() {
  INFLIGHT_MARK="$(inflight_path)" \
    || err "cannot locate the git dir of ${TARGET}; nothing written"
  {
    printf 'renovate-local.sh was writing this checkout and did not finish.\n'
    printf 'started %(%Y-%m-%dT%H:%M:%SZ)T as pid %s\n' -1 "$$"
    printf 'copies of the ORIGINAL bytes, with a MANIFEST naming each: %s\n' "${BACKUP_DIR}"
    printf '\nfiles being rewritten:\n'
    inflight_list ${BACKUP_PATHS[@]+"${BACKUP_PATHS[@]}"}
    printf '\nsubmodules being moved -- <path> <commit it was at> <branch it was\n'
    printf 'on>, and a bare "-" for a path with no checkout, which --remote does\n'
    printf 'not touch:\n'
    inflight_list ${BACKUP_LINKS[@]+"${BACKUP_LINKS[@]}"}
  } > "${INFLIGHT_MARK}" \
    || err "cannot write the in-flight marker at ${INFLIGHT_MARK}; nothing written"
}

clear_inflight() {
  [ -n "${INFLIGHT_MARK}" ] || return 0
  rm -f "${INFLIGHT_MARK}"
  INFLIGHT_MARK=""
}

# Every mode, report too (it would call wreckage "already applied"); deliberately no flag clears it.
assert_no_wreckage() {
  local mark
  mark="$(inflight_path)" || return 0
  [ -f "${mark}" ] || return 0
  note ""
  note "REFUSING to run: an earlier --apply over this checkout was KILLED before"
  note "it could either finish or undo itself, so this tree may be HALF-APPLIED"
  note "-- a manifest at its new value beside a lockfile that was never"
  note "refreshed, or a submodule moved while its manifest was not. Nothing here"
  note "can tell which, and reading it as if it were consistent is how the"
  note "wreckage gets committed. What that run was doing:"
  note ""
  sed -e 's/^/  /' "${mark}"
  note ""
  note "Put the tree right, THEN delete the marker:"
  note "  git -C ${TARGET} status                          # see what moved"
  note "  git -C ${TARGET} checkout -- <path>...           # a tracked file back"
  note "  git -C ${TARGET} submodule update -- <path>...   # a gitlink back"
  note "  rm ${mark}"
  note ""
  note "If instead you have reviewed what is there and want to KEEP it, delete"
  note "the marker on its own. Either way it is your decision, not this script's."
  err "an earlier --apply over this checkout was killed; see above"
}

# From here until the run settles, these copies are the only ones there are.
snapshot_targets() {
  BACKUP_DIR="$(mktemp -d)" || err "mktemp failed"
  BACKUP_PATHS=()
  BACKUP_STATE=taken
  printf 'renovate-local.sh kept these copies of the ORIGINAL bytes.\ncheckout: %s\nput one back by hand with: cp -p %s/<n> %s/<path>\n\n<n>\t<path>\n' \
    "${TARGET}" "${BACKUP_DIR}" "${TARGET}" > "${BACKUP_DIR}/MANIFEST" \
    || err "cannot write ${BACKUP_DIR}/MANIFEST; nothing written"
  local q
  for q in "$@"; do backup_one "${q}"; done
  for_each_lock lock_backup_one
  snapshot_gitlinks ${APPLY_PATHS[@]+"${APPLY_PATHS[@]}"}
  write_inflight
}

# The tree is now the good copy; the marker comes off first, so a kill here claims nothing.
settle_targets() {
  clear_inflight
  [ "${BACKUP_STATE}" = taken ] && BACKUP_STATE=applied
  return 0
}

# Proven back by re-reading the sha; an attached submodule is restored by ref, or its branch stays lost.
restore_gitlinks() {
  local row pth sha ref
  for row in ${BACKUP_LINKS[@]+"${BACKUP_LINKS[@]}"}; do
    IFS=$'\t' read -r pth sha ref <<<"${row}"
    [ "${sha}" = "-" ] && continue
    if [ -n "${ref}" ]; then
      "${GIT_BIN}" -C "${GIT_TARGET}/${pth}" checkout --quiet "${ref#refs/heads/}" >/dev/null 2>&1
    else
      "${GIT_BIN}" -C "${GIT_TARGET}/${pth}" checkout --quiet --detach "${sha}" >/dev/null 2>&1
    fi
    if [ "$("${GIT_BIN}" -C "${GIT_TARGET}/${pth}" rev-parse HEAD 2>/dev/null)" != "${sha}" ]; then
      RESTORE_FAILED+=("${pth}  (submodule, still not back at ${sha})")
    fi
  done
}

restore_targets() {
  local i=0 rel
  RESTORE_FAILED=()
  # Classify first: a manifest put back stops looking moved.
  tree_classify
  for rel in ${BACKUP_PATHS[@]+"${BACKUP_PATHS[@]}"}; do
    cp -p "${BACKUP_DIR}/${i}" "${TARGET}/${rel}" || RESTORE_FAILED+=("${rel}")
    i=$((i + 1))
  done
  restore_gitlinks
  # A lock tool failing half way may already have changed files beyond its lock.
  restore_collateral
  # TREE_STUCK rows are "<path>\t<why>"; RESTORE_FAILED goes straight to a human.
  while IFS= read -r rel; do
    [ -n "${rel}" ] || continue
    RESTORE_FAILED+=("${rel}")
  done < <(tree_row_text ${TREE_STUCK[@]+"${TREE_STUCK[@]}"})
  if [ "${#RESTORE_FAILED[@]}" -eq 0 ]; then
    BACKUP_STATE=restored
    # Proven put back: no half-applied tree is left for the next run to refuse.
    clear_inflight
  else
    BACKUP_STATE=stuck
  fi
}

# Undoes both halves; called from either, since either may be the one that fails.
undo_run() {
  restore_targets
  note ""
  note "$1."
  note "Every manifest and lockfile this run wrote has been put back to the bytes"
  note "it had before the run, and every submodule it moved is back at the commit"
  note "it was checked out at: a manifest whose lock could not be refreshed is"
  note "worse than an unedited one, and there is no switch to keep it."
  report_collateral_outcome
  refuse_listing "this run could not be undone -- see the list above" "" \
    "these could NOT be put back; the copies are kept at ${BACKUP_DIR}:" \
    -- ${RESTORE_FAILED[@]+"${RESTORE_FAILED[@]}"}
  err "$1 -- nothing was applied"
}

# The same undo for a signal. See docs/dependency-updates.md#a-signal-is-not-a-clean-exit
on_signal() {
  local name="$1" code="$2"
  trap - INT TERM HUP PIPE   # a second signal must not re-enter the undo
  # After SIGPIPE stdout is dead, so report the undo on stderr rather than in silence.
  [ "${name}" = PIPE ] && exec >&2
  note ""
  note "SIG${name} received -- this run is being stopped."
  if [ "${BACKUP_STATE}" = taken ]; then
    restore_targets
    note "Every manifest and lockfile this run had written is back at the bytes it"
    note "had, and every submodule it moved is back at the commit it was checked"
    note "out at. A half-applied tree is worse than an unedited one, and"
    note "a signal is not permission to leave one behind."
    report_collateral_outcome
    note_listing "these could NOT be put back; the copies are kept at ${BACKUP_DIR}:" \
      -- ${RESTORE_FAILED[@]+"${RESTORE_FAILED[@]}"} || true
  fi
  # No cleanup call here: exit runs the EXIT trap, which calls it once.
  exit "${code}"
}

# Only a settled run drops the copies; an empty RESTORE_FAILED also means "no restore attempted".
discard_backups() {
  [ -n "${BACKUP_DIR}" ] || return 0
  case "${BACKUP_STATE}" in
    applied|restored) rm -rf "${BACKUP_DIR:?}" ;;
    *) note ""
       note "the copies of every file this run touched are kept at ${BACKUP_DIR}"
       note "-- they have not been proven put back, so they are not deleted." ;;
  esac
}
