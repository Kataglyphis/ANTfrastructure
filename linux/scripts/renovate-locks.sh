#!/usr/bin/env bash
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# The lockfile half of renovate-local.sh: which lock a manifest has, the tool
# that owns it, and the copy-aside that makes "every manifest+lock pair AND every
# gitlink, or none" true across BOTH halves of an --apply. Not a standalone
# library -- renovate-local.sh owns note()/err()/refuse_listing(), TARGET and the
# GIT_BIN/GIT_TARGET pair the gitlink undo checks out with.
# docs/dependency-updates.md#the-gitlink-half-is-part-of-the-unit
[ -n "${_RENOVATE_LOCKS_SH_LOADED:-}" ] && return 0
_RENOVATE_LOCKS_SH_LOADED=1

# This half's own state. LOCK_JOBS is filled by the planner half, one
# "<manager>|<file>|<dep>" per manifest an EDIT touches.
LOCK_JOBS=(); LOCK_MISSING=(); LOCK_PLANNED=(); LOCK_DONE=()
LOCK_AMBIGUOUS=(); LOCK_FAILED=""
BACKUP_DIR=""; BACKUP_PATHS=(); RESTORE_FAILED=()

# What the copies beside the run are worth RIGHT NOW -- the only thing that says
# whether discard_backups() may delete them. See that function.
#   ""         no copies taken; nothing to keep
#   taken      the tree is being written; these are the ONLY remaining copies
#   applied    BOTH halves finished -- manifests, their locks, and the gitlinks;
#              the tree is the good copy
#   restored   every file and every gitlink was put back, and PROVEN put back
#   stuck      a restore ran and at least one of them would not go back
BACKUP_STATE=""

# The gitlink half of the same snapshot, one "<path><TAB><sha><TAB><ref>" per
# submodule this run would move. Until 2026-09-10 there was no such thing, so a
# signal or a failure in the submodule half undid nothing at all.
#
# The ref column is why a bare sha is not enough: `--remote` leaves a submodule
# DETACHED at the new tip, so putting one back means the ATTACHMENT too. It is
# empty when HEAD was already detached, and the whole row is "-" for a path with
# no checkout, which --remote does not touch. All measured; the argument is in
# docs/dependency-updates.md#the-gitlink-half-is-part-of-the-unit
BACKUP_LINKS=()

# The one thing a human is left with when this process cannot run its own undo:
# a SIGKILL, an OOM kill, a power cut. None of those can be trapped, so "fully
# applied, or exactly as it started" is not available -- and the honest answer
# is to make the NEXT run REFUSE rather than exit 0 over the wreckage, which is
# what it did until 2026-09-10. See write_inflight and assert_no_wreckage.
INFLIGHT_MARK=""

# --------------------------------------------------------------------------
# Which lock, and whose. A manifest edited without its lock refreshed is HALF a
# job, so the tool that owns the lock is part of the PRE-FLIGHT: a missing one
# refuses the whole run before anything is written.
# --------------------------------------------------------------------------

# Every <lockfile> <tool> pair this MANAGER can own, whether or not the tree
# carries it. Which one is real is a question for the tree, not for a table --
# `pep621 -> uv.lock` was hardcoded, so a pyproject.toml beside a poetry.lock
# produced NO lock job at all: manifest rewritten, lock stale, rc 0. Stdout is
# the answer here, so nothing may log to it.
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

# "<dir>/<name>", or just "<name>" at the root. One owner: lock_target,
# lock_label and lock_workspace_root all need it and `./Cargo.lock` in a message
# is a different string from `Cargo.lock` in an assertion.
rl_join() { if [ "$1" = "." ]; then printf '%s' "$2"; else printf '%s/%s' "$1" "$2"; fi; }

# Is <needle> EXACTLY one of the remaining arguments? One owner because
# tree_owned and backup_one both ask it about the same array and the duplication
# gate caught the second copy. Both used to ask it as
# `case " ${BACKUP_PATHS[*]-} " in *" $1 "*`, which is a SUBSTRING test over a
# space-joined list: one element containing a space swallows every unrelated
# path that is a fragment of it, in tree_owned by calling collateral "expected"
# and here by skipping the copy the undo would need. Measured 2026-09-11.
rl_has() {
  local needle="$1" q
  shift
  for q in "$@"; do [ "${q}" = "${needle}" ] && return 0; done
  return 1
}

# Does the manifest in <dir> belong to a WORKSPACE declared further up? A
# workspace MEMBER has no lockfile of its own -- cargo, npm, pub and uv all keep
# ONE lock at the workspace ROOT -- so `dirname <manifest>` was the wrong and
# only place lock_target looked. MEASURED 2026-09-11: crates/foo/Cargo.toml
# rewritten =1.0.100 -> =1.0.200, root Cargo.lock byte-identical, rc 0, with NO
# cargo on PATH at all -- which also proves assert_locks_runnable's "a missing
# tool is a REFUSAL" never ran, because a manifest with no lock job is a
# manifest with no tool to be missing. Same bug class the pep621 comment above
# records, on the other axis: there the NAME was resolved from a table, here the
# DIRECTORY was.
#
# It stops at the first ancestor that DECLARES a workspace of this manager's
# kind, and at nothing else. "Walk up until some ancestor has a lockfile" is the
# bug in the other direction: `app/pubspec.yaml` beside an unrelated root
# `pubspec.lock` would get a lock job pointed at a file it has nothing to do
# with, and (K10) is exactly that tree. The declaration is what makes an
# ancestor's lock this manifest's lock.
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

# The lockfile(s) that own this manifest, one "<lockfile> <tool> <dir>" per line
# -- <dir> LAST, because it is the only field that can contain a space and
# `read -r lock tool dir` hands the last field the rest of the line:
#   rc 0  exactly one, and that one owns the manifest
#   rc 1  none in this tree, so this edit creates no lock job at all
#   rc 2  SEVERAL. Which tool owns the manifest is not knowable, and picking one
#         is how a lock goes stale behind a green run -- the caller refuses.
# Beside the manifest FIRST and the workspace root only then: a member that does
# carry its own lock owns that one.
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

# The path a lock job names, spelled as a reviewer would write it: the directory
# the LOCK is in, which for a workspace member is not the manifest's own.
lock_label() { rl_join "$1" "$2"; printf '\n'; }

# A cargo package-id spec is `name[@partial-version]`, and the version part is a
# PARTIAL VERSION -- `1.0` -- never a requirement: `=2.12.0` is rejected with
# "unexpected version requirement". It is what disambiguates a bare name when
# the lockfile holds two versions of the crate: `cargo update -p wgpu` refuses
# with "specification `wgpu` is ambiguous" once wgpu 29 and 30 are both in the
# lock (measured on OxidANT 2026-09-11), and the manifest's own range picks the
# lineage. Operators are stripped and anything that is not a dotted number
# falls back to the bare name, which is what a `*` or a comma range gets.
cargo_spec() {
  local dep="$1" cur="${2:-}" v
  v="${cur//[ =^~<>]/}"
  case "${v}" in
    ""|*[!0-9.]*) printf '%s' "${dep}" ;;
    *) printf '%s@%s' "${dep}" "${v}" ;;
  esac
}

# cargo is the one lock tool that can need a SECOND attempt, so it gets its own
# runner beside the shared table. Both failure modes are measured:
#   * spec too WIDE -- `cargo update -p wgpu` is ambiguous while the lock holds
#     wgpu 29 and 30, which is what the manifest's range disambiguates;
#   * spec too NARROW -- an earlier job in the SAME run re-resolved the
#     workspace and already carried the crate past the range the manifest named
#     (`flutter_rust_bridge =2.12.0 -> =2.13.0`: job N moved it, job N+1's
#     `@2.12.0` matched nothing), so the bare name -- unambiguous by then -- is
#     the retry.
run_cargo_lock() {
  local dir="$1" dep="$2" cur="$3" spec
  spec="$(cargo_spec "${dep}" "${cur}")"
  ( cd "${dir}" && cargo update -p "${spec}" ) && return 0
  [ "${spec}" = "${dep}" ] && return 1
  ( cd "${dir}" && cargo update -p "${dep}" )
}

# The one command each lock tool needs, run in the directory that owns the
# LOCKFILE -- the manifest's own for a standalone package, the workspace ROOT for
# a member. `npm install --package-lock-only` in a member directory writes a
# member-level lock instead of refreshing the root one, which is a second stale
# lock rather than none.
# Keyed by TOOL rather than manager, because npm/yarn/pnpm are one manager with
# three lockfiles. A tool with no row here is an ERROR: silently doing nothing
# would report a refreshed lock that was never refreshed. The `cd` is hoisted
# out of the arms deliberately -- one `&&` per arm is one branch per arm, and
# nine of them put this function over the complexity gate's limit.
run_lock_tool() {
  local tool="$1" dir="$2" dep="$3" cur="$4"
  local -a argv=()
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

# Every lock job that HAS exactly one lockfile in this tree, handed to <fn> as
#   <fn> <tool> <dep> <lockfile-dir> <label> <declared-value>
# One walk with the consumer as the argument: the pre-flight, the dry-run plan,
# the backup and the real refresh all need the same list, and four copies of the
# same `IFS='|' read` plus lock_target round trip is exactly the clone the
# duplication gate catches. A manifest sitting beside SEVERAL lockfiles is not
# handed on at all -- it is recorded in LOCK_AMBIGUOUS, which the pre-flight
# turns into a refusal before anything is written. The declared value rides
# along because cargo needs it to disambiguate a crate the lockfile holds twice
# (cargo_spec), and only the refresh consumer reads it.
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
    "${fn}" "${tool}" "${dep}" "${dir}" "$(lock_label "${dir}" "${lock}")" "${cur}"
  done
}

# The four consumers of that walk. Args: <tool> <dep> <dir> <label> <value>.
lock_missing_one() {
  if ! command -v "$1" >/dev/null 2>&1; then
    LOCK_MISSING+=("$4 needs '$1', which is not on this PATH")
  fi
}

lock_planned_one() { LOCK_PLANNED+=("$4 via $1"); }

# A lock tool that FAILS records the failure and stops the walk; it does not
# abort the process, because the manifests are already written by then and the
# contract is that the whole set is undone. See undo_run below.
lock_refresh_one() {
  if [ -n "${LOCK_FAILED}" ]; then return 0; fi
  note "  $4 via $1"
  if ! run_lock_tool "$1" "${TARGET}/$3" "$2" "$5"; then
    LOCK_FAILED="'$1' could not refresh $4"
    return 0
  fi
  LOCK_DONE+=("$4")
}

# The file a lock job would rewrite, for the backup walk. $4 is the label, which
# is already the repo-relative path.
lock_backup_one() { backup_one "$4"; }

# Every lock tool this run would need, checked while the tree is still
# untouched. A missing tool is a REFUSAL, not a warning: the alternative is a
# committed manifest whose lock disagrees with it. So is an ambiguous one.
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
  # And can the lockfile be READ at all? Asked here so that the SAME reading
  # after the tool ran means "the tool broke it" rather than "it was already
  # broken" -- two states this run must not confuse, because only one of them is
  # its fault and they call for opposite responses.
  lock_probe_all
  refuse_listing "unreadable lockfile(s) -- see the list above" \
    "Fix or regenerate the lockfile with its own tool, then re-run." \
    "REFUSING to apply: a lockfile this run would refresh cannot be read by the" \
    "real parser for its format BEFORE anything is written. Editing a manifest" \
    "beside a lockfile nobody can parse is not an update, it is a second" \
    "problem stacked on the first:" \
    -- ${LOCK_UNREADABLE[@]+"${LOCK_UNREADABLE[@]}"}
}

# --------------------------------------------------------------------------
# What is checkable about a LOCKFILE, once its tool has rewritten it.
#
# A lockfile is legitimately rewritten WHOLESALE, so there is no "exactly one
# leaf changed" to assert and pretending otherwise would be the more dishonest
# option. What IS refused, what is only reported, and what is not checked at all
# -- with the reason for each -- is renovate_planner.py lock_readable() and
# docs/dependency-updates.md#what-can-be-said-about-a-lockfile
# --------------------------------------------------------------------------
LOCK_UNREADABLE=(); LOCK_SAID=()

# It is asked TWICE and the two readings mean different things: before the first
# byte an unreadable lockfile is the TREE's problem and the run refuses without
# writing; afterwards the same reading is the TOOL's problem and the run is
# undone. Without the pre-flight the second could not tell them apart.
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
  note "refreshing the lockfile(s) the edits made stale:"
  LOCK_DONE=()
  LOCK_FAILED=""
  for_each_lock lock_refresh_one
  if [ "${#LOCK_DONE[@]}" -eq 0 ] && [ -z "${LOCK_FAILED}" ]; then
    note "  (none of the edited manifests has a lockfile in this tree)"
  fi
}

# --------------------------------------------------------------------------
# The undo. A pre-flight can prove a lock tool EXISTS; it cannot prove the tool
# will succeed, so the bytes are kept: every file the manifest half is about to
# write is copied aside first, and a lock tool that fails puts all of them back.
# docs/dependency-updates.md#all-of-it-or-none-of-it
# --------------------------------------------------------------------------
backup_one() {
  local rel="$1" n
  rl_has "${rel}" ${BACKUP_PATHS[@]+"${BACKUP_PATHS[@]}"} && return 0
  [ -f "${TARGET}/${rel}" ] || return 0
  n="${#BACKUP_PATHS[@]}"
  cp -p "${TARGET}/${rel}" "${BACKUP_DIR}/${n}" \
    || err "cannot copy ${rel} aside before writing it; nothing written"
  # Which path this copy came from, written to DISK the moment the copy is
  # taken. The array above is the same mapping, and until 2026-09-10 it was the
  # only one: after a kill it died with the process, leaving a directory holding
  # files literally called 0 and 1 and nothing at all to say where either
  # belonged. A copy nobody can place is not a backup.
  printf '%s\t%s\n' "${n}" "${rel}" >> "${BACKUP_DIR}/MANIFEST" \
    || err "cannot record ${rel} in ${BACKUP_DIR}/MANIFEST; nothing written"
  BACKUP_PATHS+=("${rel}")
}

# Where each submodule this run would move is checked out RIGHT NOW. Reading
# HEAD inside the submodule, rather than the superproject's `HEAD:<path>`, is
# deliberate: `--remote` moves the submodule's WORKING TREE and leaves the
# superproject's index alone, so the working tree is what has to go back.
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

# The marker's path: inside the target's OWN git dir, so it is per-checkout,
# survives the process that wrote it, cannot be committed by accident, and is
# found by the next run over the same tree whatever TMPDIR that run was given.
inflight_path() {
  local gd
  gd="$(git -C "${TARGET}" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  printf '%s/renovate-local-inflight\n' "${gd}"
}

# One indented item per line, and an explicit "(none)" for an empty list. A
# blank line under a heading reads as "the tool forgot to say", which is the
# wrong impression for the only artefact a human is left holding after a kill.
inflight_list() {
  if [ "$#" -eq 0 ]; then printf '  (none)\n'; else printf '  %s\n' "$@"; fi
}

# Written BEFORE the first byte goes anywhere, deleted when the run settles or
# is proven put back. Everything a human needs is IN it, because the process
# that knew the rest is by then dead: which files, which submodules and the
# commit each one was at, and where the copies of the original bytes are.
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

# The next run's first question, and the only honest answer to a kill that could
# not be trapped. It runs in EVERY mode that reads the tree, report included: a
# report over a half-applied checkout says "already applied" about a manifest
# whose lockfile was never refreshed, which is the wreckage rendered as good
# news. There is deliberately no flag that clears this -- a switch to ignore a
# half-applied tree is the tolerated failure this whole file exists to refuse.
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

# <file>... -- the manifests, plus every lockfile a lock job would rewrite, plus
# the commit every submodule this run would move is sitting at. From here until
# the run settles, these copies are the only ones there are.
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

# BOTH halves are done -- every manifest written, every lockfile it made stale
# refreshed, every gitlink moved. The tree is now the good copy, so the copies
# beside the run may go and the marker comes off.
# The marker comes off FIRST: once both halves are done the tree is complete, so
# a kill landing inside this function should leave no claim that it might not be.
settle_targets() {
  clear_inflight
  [ "${BACKUP_STATE}" = taken ] && BACKUP_STATE=applied
  return 0
}

# Every gitlink back where snapshot_gitlinks found it, and PROVEN back: a
# checkout that reports success and leaves HEAD somewhere else is exactly the
# failure this half exists to catch, so the sha is read back and compared. The
# recorded ref, not the sha, is what a still-attached submodule is checked out
# by -- `checkout --detach <sha>` would put the commit back and the branch not.
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
  # FIRST, before a single byte goes back: work out what moved that this run does
  # NOT own. Restoring the manifests first would erase the evidence -- the
  # comparison is against how the tree stood before the run, and a manifest put
  # back stops looking moved. See renovate-tree.sh, tree_classify().
  tree_classify
  for rel in ${BACKUP_PATHS[@]+"${BACKUP_PATHS[@]}"}; do
    cp -p "${BACKUP_DIR}/${i}" "${TARGET}/${rel}" || RESTORE_FAILED+=("${rel}")
    i=$((i + 1))
  done
  restore_gitlinks
  # ...and the collateral an ecosystem tool left behind, which until 2026-09-10
  # nothing put back: a lock tool that failed HALF WAY through had already
  # deleted three generated files by then, and this function restored only the
  # manifest and the lock.
  restore_collateral
  # TREE_STUCK rows are "<path><TAB><why>"; RESTORE_FAILED is printed straight
  # to a human, so they are rendered on the way in.
  while IFS= read -r rel; do
    [ -n "${rel}" ] || continue
    RESTORE_FAILED+=("${rel}")
  done < <(tree_row_text ${TREE_STUCK[@]+"${TREE_STUCK[@]}"})
  if [ "${#RESTORE_FAILED[@]}" -eq 0 ]; then
    BACKUP_STATE=restored
    # Proven put back, one file and one gitlink at a time: there is no longer a
    # half-applied tree for the next run to refuse over.
    clear_inflight
  else
    BACKUP_STATE=stuck
  fi
}

# The undo for the WHOLE run, both halves. It is called from the manifest half
# and from the gitlink half, because either can be the one that fails and the
# tree has to end up in one piece whichever it was.
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

# The same undo, run because somebody STOPPED the run rather than because a
# tool failed. A signal is not a clean exit, and until 2026-09-10 this was
# treated as one: with a lock tool part way through, SIGINT ended the run at
# rc 0 printing "Nothing is staged or committed", SIGTERM at 143 and SIGHUP at
# 129, all three leaving the manifest written and the copies already deleted.
# docs/dependency-updates.md#a-signal-is-not-a-clean-exit
on_signal() {
  local name="$1" code="$2"
  trap - INT TERM HUP PIPE   # a second signal must not re-enter the undo
  # SIGPIPE means stdout is a pipe nobody is reading any more -- `| head`, or
  # `| less` and then q. Every note() below would go to that dead pipe and the
  # undo would happen in silence, so say it on stderr instead, which the pipe
  # left open. This is the one signal a human sends by accident rather than on
  # purpose, and it used to be the one that was not caught at all.
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

# The copies go only when the run SETTLED: every file written and its locks
# refreshed, or every file proven put back one by one. "RESTORE_FAILED is empty"
# was not that test -- it is also empty when no restore was ever ATTEMPTED,
# which is the state a signal left behind while cleanup() deleted the only
# copies there were.
discard_backups() {
  [ -n "${BACKUP_DIR}" ] || return 0
  case "${BACKUP_STATE}" in
    applied|restored) rm -rf "${BACKUP_DIR:?}" ;;
    *) note ""
       note "the copies of every file this run touched are kept at ${BACKUP_DIR}"
       note "-- they have not been proven put back, so they are not deleted." ;;
  esac
}
