#!/usr/bin/env bash
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# renovate-fleet.sh -- renovate-local.sh over every family repo, in landing order. See docs/dependency-updates.md#the-fleet
set -uo pipefail

# Shared with renovate-local.sh so a refusal reads the same in both; the argument signs fatal messages.
# shellcheck source=renovate-say.sh
. "$(dirname "${BASH_SOURCE[0]}")/renovate-say.sh" renovate-fleet.sh \
  || { printf 'renovate-fleet.sh: cannot load renovate-say.sh beside me\n' >&2; exit 1; }

rule() { note "=============================================================="; }

# A function: an inline `&&`/`||` pair inside the heading is easy to get backwards.
budget_text() {
  if [ "${BUDGET}" -gt 0 ]; then printf '%ss per repo' "${BUDGET}"; return 0; fi
  printf 'OFF (--timeout 0): one repo CAN hold this run for ever'
}

# A heredoc, not a header sed-ed back out: usage is interface, and comments get shortened.
usage() {
  cat <<'USAGE'
renovate-fleet.sh [--apply [--dry-run]] [--only <csv>] [--skip <csv>]
                  [--here] [--managers <csv>] [--timeout <seconds>] [<root>]

  (no flags)      report what is behind, in every repo of the fleet
  --apply         and write it, in dependency order
  --dry-run       print the whole plan -- fleet and per repo -- and write nothing
  --only <csv>    keep only these repo directory names
  --skip <csv>    drop these
  --here          this repo only; no fleet discovery at all
  --vendored      ALSO run in vendored checkouts that are the only copy of one
                  of the owner's repos (opt-in; dependency-updates.md#the-fleet)
  --managers <csv>  passed straight through to renovate-local.sh
  --timeout <s>   per-repo wall clock, default 600; 0 turns the budget OFF

exit codes, composed from the per-repo ones, worst first:
  0    every repo finished, and every reported update is at its new value
  1    at least one repo could NOT complete; its own tree is as it was
  2    every repo completed, and at least one reported update was not applied
  130  INTERRUPTED (SIGINT). 129 SIGHUP, 141 SIGPIPE, 143 SIGTERM. The repo
       that was running finished or rolled itself back, no repo after it was
       started, and the summary names every one that was not.
USAGE
}

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL="${SELF_DIR}/renovate-local.sh"
[ -f "${LOCAL}" ] || err "renovate-local.sh is missing at ${LOCAL}"

MODE=report
DRY_RUN=0
HERE=0
# Off by default: with one repo in several checkouts, write in exactly one of them.
VENDORED_MODE=0
ONLY=""; SKIP=""; MANAGERS=""
ROOT=""
# Per-repo seconds, not a network knob: one huge repo must not hold the rest of the fleet.
BUDGET=600
# The rollback window between TERM and KILL; a KILL cannot be trapped.
BUDGET_GRACE=30

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)      MODE=apply ;;
    --report)     MODE=report ;;
    --dry-run)    DRY_RUN=1; MODE=apply ;;
    --here)       HERE=1 ;;
    --vendored|--in-place) VENDORED_MODE=1 ;;
    --only)       shift; [ $# -gt 0 ] || err "--only needs a value"; ONLY="$1" ;;
    --only=*)     ONLY="${1#*=}" ;;
    --skip)       shift; [ $# -gt 0 ] || err "--skip needs a value"; SKIP="$1" ;;
    --skip=*)     SKIP="${1#*=}" ;;
    --managers)   shift; [ $# -gt 0 ] || err "--managers needs a value"; MANAGERS="$1" ;;
    --managers=*) MANAGERS="${1#*=}" ;;
    --timeout)    shift; [ $# -gt 0 ] || err "--timeout needs a value"; BUDGET="$1" ;;
    --timeout=*)  BUDGET="${1#*=}" ;;
    -h|--help)    usage; exit 0 ;;
    -*)           err "unknown option: $1" ;;
    *)            [ -z "${ROOT}" ] || err "more than one root given"; ROOT="$1" ;;
  esac
  shift
done

case "${BUDGET}" in
  ''|*[!0-9]*) err "--timeout takes whole seconds (0 turns the budget off), not '${BUDGET}'" ;;
esac
# A budget nothing can enforce is refused rather than silently ignored.
if [ "${BUDGET}" -gt 0 ] && ! command -v timeout >/dev/null 2>&1; then
  err "no 'timeout' on PATH, so the ${BUDGET}s per-repo budget cannot be enforced -- install coreutils, or run with --timeout 0 and accept that one repo can hold the fleet"
fi

ROOT="${ROOT:-$PWD}"
[ -d "${ROOT}" ] || err "not a directory: ${ROOT}"
ROOT="$(cd "${ROOT}" && pwd)"
git -C "${ROOT}" rev-parse --git-dir >/dev/null 2>&1 || err "not a git repo: ${ROOT}"
ROOT="$(git -C "${ROOT}" rev-parse --show-toplevel)"

# Identity is the normalised remote (host/owner/name), one key for every path and url spelling; an ssh :port breaks it.
normalize_url() {
  printf '%s' "$1" \
    | sed -e 's#^[a-zA-Z+]*://##' -e 's#^[^@/]*@##' -e 's#:#/#' \
          -e 's#\.git$##' -e 's#/*$##' \
    | tr '[:upper:]' '[:lower:]'
}

repo_identity() {
  local url
  url="$(git -C "$1" config --get remote.origin.url 2>/dev/null)" || return 1
  [ -n "${url}" ] || return 1
  normalize_url "${url}"
}

# The owner comes from the root's own remote, never from a name list.
identity_owner() { printf '%s' "$1" | cut -d/ -f1,2; }

# Stopping: bash defers the handler until the running child returns, which lets it roll its own tree back first.
FLEET_STOP=""
FLEET_STOP_RC=0
NOT_RUN=()

stop_run() {
  [ -z "${FLEET_STOP}" ] || return 0
  FLEET_STOP="$1"
  FLEET_STOP_RC="$2"
  note ""
  note "*** STOPPING: $1"
  note "*** No repo after this one is started. What was already written is in"
  note "*** the summary below, and nothing here is staged, committed or pushed."
}

trap 'stop_run "SIGINT -- you asked this to stop." 130' INT
trap 'stop_run "SIGTERM." 143' TERM
trap 'stop_run "SIGHUP -- the terminal went away." 129' HUP
trap 'stop_run "SIGPIPE -- the reader of this output went away." 141' PIPE

# Discovery: climb to the outermost superproject, so a run from any subrepo equals one from the top.
climb_to_top() {
  local here="$1" up n=0
  while [ "${n}" -lt "${MAX_DEPTH}" ]; do
    up="$(git -C "${here}" rev-parse --show-superproject-working-tree 2>/dev/null)"
    [ -n "${up}" ] || break
    here="${up}"
    n=$((n + 1))
  done
  printf '%s' "${here}"
}

# Not a tuning knob: a .gitmodules pointing at an ancestor would otherwise recurse forever.
MAX_DEPTH=8

# Emits "<checkout|uninit>\t<identity>\t<abs path>\t<vendoring repo>"; an uninit submodule keeps its edge.
walk_submodules() {
  local dir="$1" depth="$2" name path abs id declared
  [ "${depth}" -gt 0 ] || return 0
  [ -f "${dir}/.gitmodules" ] || return 0
  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    path="$(git -C "${dir}" config -f .gitmodules --get "submodule.${name}.path" 2>/dev/null)"
    [ -n "${path}" ] || continue
    abs="${dir}/${path}"
    declared="$(normalize_url "$(git -C "${dir}" config -f .gitmodules --get "submodule.${name}.url" 2>/dev/null)")"
    if [ ! -e "${abs}/.git" ]; then
      printf 'uninit\t%s\t%s\t%s\n' "${declared}" "${abs}" "${dir}"
      continue
    fi
    id="$(repo_identity "${abs}" 2>/dev/null)" || id=""
    [ -n "${id}" ] || id="${declared}"
    printf 'checkout\t%s\t%s\t%s\n' "${id}" "${abs}" "${dir}"
    walk_submodules "${abs}" $((depth - 1))
  done < <(git -C "${dir}" config -f .gitmodules --name-only --get-regexp '\.path$' 2>/dev/null \
           | sed -e 's/^submodule\.//' -e 's/\.path$//')
}

TOP=""; FAMILY_DIR=""; OWNER=""
OWN_PATHS=(); OWN_IDS=(); OWN_NAMES=(); OWN_DEPS=()
VENDORED=(); DUPLICATES=(); NO_OWN=(); SELF_VENDORED=(); CYCLES=(); EXTERNAL=0
UNINIT=(); NO_IDENTITY=(); FOREIGN=()
GRAPH=""

# Own checkouts sit one level beside the top; a recursive sweep would reach scratch clones.
discover_own() {
  local d id rem
  TOP="$(climb_to_top "${ROOT}")"
  FAMILY_DIR="$(dirname "${TOP}")"
  OWNER="$(identity_owner "$(repo_identity "${TOP}" || true)")"
  [ -n "${OWNER}" ] || err "${TOP} has no origin remote, so 'the same owner' has no meaning here; run with --here"
  for d in "${FAMILY_DIR}"/*; do
    [ -e "${d}/.git" ] || continue
    id="$(repo_identity "${d}" 2>/dev/null)" || id=""
    # Collected, not dropped: a checkout without origin must still be named.
    if [ -z "${id}" ]; then
      rem="$(git -C "${d}" remote 2>/dev/null | tr '\n' ' ')"
      NO_IDENTITY+=("$(basename "${d}")  (remotes here: ${rem:-none at all})")
      continue
    fi
    if [ "$(identity_owner "${id}")" != "${OWNER}" ]; then
      FOREIGN+=("$(basename "${d}")  is ${id}")
      continue
    fi
    OWN_PATHS+=("${d}"); OWN_IDS+=("${id}"); OWN_NAMES+=("$(basename "${d}")")
  done
}

# One walk per own repo, rows tagged with that repo so the ordering reuses them.
discover_graph() {
  local i state id abs owner_dir
  GRAPH="$(mktemp)" || err "mktemp failed"
  for i in "${!OWN_PATHS[@]}"; do
    walk_submodules "${OWN_PATHS[$i]}" "${MAX_DEPTH}" \
      | sed -e "s#^#${i}\t#" >> "${GRAPH}"
    OWN_DEPS+=(" ")
  done
  while IFS=$'\t' read -r i state id abs owner_dir; do
    if [ -n "${id}" ]; then classify_vendored "${i}" "${state}" "${id}" "${abs}" "${owner_dir}"; fi
  done < "${GRAPH}"
  # Before close_deps, which would make a three-repo cycle look like a mutual pair.
  find_cycles
  close_deps
  return 0
}

# Kinds: a self copy (named), a member's second checkout (an order edge), an owner repo with no own checkout (named), foreign (counted).
classify_vendored() {
  local i="$1" state="$2" id="$3" abs="$4" owner_dir="$5"
  # A second `local`: a name assigned in the same `local` is not visible yet in every shell (SC2318).
  local rel="${abs#${FAMILY_DIR}/}"
  local by="${owner_dir#${FAMILY_DIR}/}"
  if [ "${state}" = uninit ]; then
    UNINIT+=("${rel}  is ${id}, declared by ${by}")
  fi
  if [ "${id}" = "${OWN_IDS[$i]}" ]; then
    case " ${SELF_VENDORED[*]-} " in
      *" ${OWN_NAMES[$i]} "*) ;;
      *) SELF_VENDORED+=("${OWN_NAMES[$i]}") ;;
    esac
    return 0
  fi
  # The declared edge orders the fleet even without a checkout; only the listing needs a tree.
  case " ${OWN_IDS[*]-} " in
    *" ${id} "*)
      add_dep "${i}" "${id}"
      [ "${state}" = uninit ] || DUPLICATES+=("${rel}  is ${id}, vendored by ${by}")
      return 0 ;;
  esac
  if [ "$(identity_owner "${id}")" != "${OWNER}" ]; then
    [ "${state}" = uninit ] || EXTERNAL=$((EXTERNAL + 1))
    return 0
  fi
  [ "${state}" = uninit ] && return 0
  VENDORED+=("${rel}  is ${id}")
  case " ${NO_OWN[*]-} " in
    *" ${id} "*) ;;
    *) NO_OWN+=("${id}") ;;
  esac
  return 0
}

add_dep() {
  case "${OWN_DEPS[$1]}" in
    *" $2 "*) return 0 ;;
    *) OWN_DEPS[$1]="${OWN_DEPS[$1]}$2 " ;;
  esac
}

own_index() {
  local k
  for k in "${!OWN_IDS[@]}"; do
    if [ "${OWN_IDS[$k]}" = "$1" ]; then printf '%s' "${k}"; return 0; fi
  done
  return 1
}

# Order: rank by transitive fleet deps, topological since vendoring makes deps a superset. See docs/dependency-updates.md#order

# Union in each member's own deps to a fixpoint: an uninit submodule hides its subtree from the walk.
close_deps() {
  local i j d d2 changed=1
  while [ "${changed}" -eq 1 ]; do
    changed=0
    for i in "${!OWN_IDS[@]}"; do
      for d in ${OWN_DEPS[$i]}; do
        j="$(own_index "${d}")" || continue
        for d2 in ${OWN_DEPS[$j]}; do
          [ "${d2}" != "${OWN_IDS[$i]}" ] || continue
          case "${OWN_DEPS[$i]}" in *" ${d2} "*) continue ;; esac
          OWN_DEPS[$i]="${OWN_DEPS[$i]}${d2} "
          changed=1
        done
      done
    done
  done
}

dep_count() { printf '%s' "$1" | wc -w | tr -d ' '; }

# A mutual pair has no correct order, so it is reported rather than ordered arbitrarily.
find_cycles() {
  local i j
  for i in "${!OWN_IDS[@]}"; do
    for j in "${!OWN_IDS[@]}"; do
      [ "${i}" -lt "${j}" ] || continue
      case "${OWN_DEPS[$i]}" in *" ${OWN_IDS[$j]} "*) ;; *) continue ;; esac
      case "${OWN_DEPS[$j]}" in *" ${OWN_IDS[$i]} "*) ;; *) continue ;; esac
      CYCLES+=("${OWN_NAMES[$i]} and ${OWN_NAMES[$j]} vendor EACH OTHER")
    done
  done
}

ORDER_PATHS=(); ORDER_NAMES=(); ORDER_IDS=()
order_fleet() {
  local i name path id sorted
  sorted="$(mktemp)" || err "mktemp failed"
  for i in "${!OWN_PATHS[@]}"; do
    printf '%s\t%s\t%s\t%s\n' "$(dep_count "${OWN_DEPS[$i]}")" \
      "${OWN_NAMES[$i]}" "${OWN_PATHS[$i]}" "${OWN_IDS[$i]}" >> "${sorted}"
  done
  while IFS=$'\t' read -r _ name path id; do
    [ -n "${name}" ] || continue
    selected "${name}" || continue
    ORDER_PATHS+=("${path}"); ORDER_NAMES+=("${name}"); ORDER_IDS+=("${id}")
  done < <(sort -t$'\t' -k1,1n -k2,2 "${sorted}")
  rm -f "${sorted}"
}

# Appended last: a vendored copy is downstream of all. See docs/dependency-updates.md#the-same-repo-checked-out-several-times
ORDER_VENDORED=0
order_vendored_in_place() {
  local id row rel
  for id in ${NO_OWN[@]+"${NO_OWN[@]}"}; do
    row="$(printf '%s\n' ${VENDORED[@]+"${VENDORED[@]}"} | grep -m1 -- "is ${id}\$" || true)"
    [ -n "${row}" ] || continue
    rel="${row%%  is *}"
    selected "$(basename "${rel}")" || continue
    ORDER_PATHS+=("${FAMILY_DIR}/${rel}")
    ORDER_NAMES+=("$(basename "${rel}") (vendored)")
    ORDER_IDS+=("${id}")
    ORDER_VENDORED=$((ORDER_VENDORED + 1))
  done
}

# --skip wins; a name in neither list is in only while --only is empty.
selected() {
  local name="$1" w
  local -a want=()
  if [ -n "${SKIP}" ]; then
    IFS=',' read -r -a want <<<"${SKIP}"
    for w in ${want[@]+"${want[@]}"}; do [ "${w}" = "${name}" ] && return 1; done
  fi
  [ -n "${ONLY}" ] || return 0
  IFS=',' read -r -a want <<<"${ONLY}"
  for w in ${want[@]+"${want[@]}"}; do [ "${w}" = "${name}" ] && return 0; done
  return 1
}

# Which of two own checkouts is pushed from is unknowable, so refuse. See docs/dependency-updates.md#the-same-repo-checked-out-several-times
refuse_duplicate_own() {
  local i j
  local -a dups=()
  for i in "${!ORDER_IDS[@]}"; do
    for j in "${!ORDER_IDS[@]}"; do
      [ "${i}" -lt "${j}" ] || continue
      [ "${ORDER_IDS[$i]}" = "${ORDER_IDS[$j]}" ] || continue
      dups+=("${ORDER_IDS[$i]}  is checked out at BOTH  ${ORDER_PATHS[$i]}  AND  ${ORDER_PATHS[$j]}")
    done
  done
  refuse_listing \
    "two working trees of one repository are both in the run order" \
    "  Say which one you push from: --only, or --skip <the other directory name>. Nothing has been written." \
    "TWO OWN CHECKOUTS OF ONE REPOSITORY. These are not a vendored copy and a" \
    "source -- they are two working trees a human pushes from, and an --apply" \
    "into both leaves one repository with two divergent trees and a human to" \
    "decide which to keep. That is the accident this whole tool is shaped" \
    "around, so it refuses rather than guesses:" \
    -- ${dups[@]+"${dups[@]}"}
}

# Plan
print_plan() {
  local i
  rule
  note "the fleet, as found -- not a list written down here:"
  note "  top superproject : ${TOP}"
  note "  looked beside it : ${FAMILY_DIR}"
  note "  same owner as    : ${OWNER}"
  note "  per-repo budget  : $(budget_text)"
  rule
  note ""
  note "run order -- a repo runs AFTER every fleet repo it vendors, and this is"
  note "also the order to LAND the results in (nothing here commits or pushes,"
  note "so a consumer cannot see a hub change until you push the hub):"
  for i in "${!ORDER_NAMES[@]}"; do
    printf '  %2d. %-26s %s\n' "$((i + 1))" "${ORDER_NAMES[$i]}" "${ORDER_PATHS[$i]}"
  done
  if note_listing \
      "A CYCLE. There is no correct order for these, and the order above is" \
      "therefore an arbitrary choice rather than a plan:" \
      -- ${CYCLES[@]+"${CYCLES[@]}"}; then
    note "  Land one of them first by hand, deliberately, and break the cycle."
  fi
  note_listing "these vendor a copy of THEMSELVES, which constrains no order" \
    "but is worth knowing about:" \
    -- ${SELF_VENDORED[@]+"${SELF_VENDORED[@]}"} || true
  print_duplicates
  print_unplaced
}


# A count and one example per repo: listing every vendored copy buried the answers.
NO_OWN_ROWS=()
summarise_no_own() {
  local id n first
  for id in ${NO_OWN[@]+"${NO_OWN[@]}"}; do
    n="$(printf '%s\n' ${VENDORED[@]+"${VENDORED[@]}"} | grep -c -- "is ${id}\$" || true)"
    first="$(printf '%s\n' ${VENDORED[@]+"${VENDORED[@]}"} | grep -m1 -- "is ${id}\$" || true)"
    NO_OWN_ROWS+=("${id}  (${n} vendored copy(ies), e.g. ${first%%  is *})")
  done
}

# Update a repo where it lives, move only pointers where it is vendored. See docs/dependency-updates.md#the-same-repo-checked-out-several-times
print_duplicates() {
  summarise_no_own
  # `git submodule update --remote` checks out inside the copy, so never claim it stays untouched.
  if note_listing \
      "THE SAME REPO, CHECKED OUT AGAIN. Each of these is a second working" \
      "tree of a repo the fleet already updates above. No update is APPLIED in" \
      "one: what moves here is the POINTER, and the run over the repo that" \
      "declares it is what moves it -- with \`git submodule update --remote\`," \
      "which does check the new commit out inside the copy." \
      -- ${DUPLICATES[@]+"${DUPLICATES[@]}"}; then
    note ""
    note "  After landing the run above, \`git submodule update\` in the repo that"
    note "  declares each one brings its checkout to the pointer."
  fi
  if note_listing \
      "these are yours, and this machine has no OWN checkout of them -- only" \
      "vendored copies. The fleet moves the pointers TO them and does NOT" \
      "update them; clone one beside the others to bring it into the fleet:" \
      -- ${NO_OWN_ROWS[@]+"${NO_OWN_ROWS[@]}"}; then
    note "  (git clone <url> ${FAMILY_DIR}/<name>)"
  fi
  if [ "${EXTERNAL}" -gt 0 ]; then
    note ""
    note "${EXTERNAL} further vendored checkout(s) belong to somebody else and are"
    note "pointer targets only -- the gitlink half of their own superproject's run"
    note "moves them, and nothing here writes inside one."
  fi
}

# Name what the fleet could not place instead of staying silent about it.
print_unplaced() {
  if note_listing \
      "UNINITIALISED SUBMODULE(S). There is no checkout here, so nothing can" \
      "read what THEY vendor. Where the same repo is a fleet member its own" \
      "checkout supplied the missing edges; where it is not, the rank above is" \
      "a floor rather than a fact and the order may be understated:" \
      -- ${UNINIT[@]+"${UNINIT[@]}"}; then
    note "  \`git submodule update --init --recursive\` in the repo that declares"
    note "  each one makes it visible, and makes the order above a measurement."
  fi
  if note_listing \
      "these are git checkouts beside ${FAMILY_DIR} that this run cannot" \
      "PLACE: identity here IS \`remote.origin.url\`, and there is none, so" \
      "there is no owner to compare against ${OWNER}. They are NOT in the run:" \
      -- ${NO_IDENTITY[@]+"${NO_IDENTITY[@]}"}; then
    note "  \`git -C <dir> remote add origin <url>\` brings one into the fleet."
  fi
  note_listing \
    "these are checkouts beside ${FAMILY_DIR} belonging to somebody else." \
    "The fleet stops at the owner, so they are named and not run:" \
    -- ${FOREIGN[@]+"${FOREIGN[@]}"} || true
}

# Running one repo without letting it take the others with it
RESULTS=()
WORST=0

record() {
  RESULTS+=("$(printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4")")
  case "$3" in
    0) ;;
    2) [ "${WORST}" -eq 1 ] || WORST=2 ;;
    # Any rc outside the contract (a signal, a crash) is "could not complete".
    *) WORST=1 ;;
  esac
}

# An unworkable repo becomes a named row rather than a wall of output.
preflight_repo() {
  local dir="$1" name="$2" branch gd
  gd="$(git -C "${dir}" rev-parse --absolute-git-dir 2>/dev/null)" || gd=""
  if [ -z "${gd}" ]; then
    record "${name}" preflight 1 "git will not name a git dir here"
    return 1
  fi
  if [ -f "${gd}/renovate-local-inflight" ]; then
    record "${name}" preflight 1 "an earlier --apply here was killed; see ${gd}/renovate-local-inflight"
    return 1
  fi
  preflight_in_progress "${dir}" "${name}" "${gd}" || return 1
  # Detached HEAD refuses (the human's commit would get lost); last, as a rebase detaches HEAD too.
  branch="$(git -C "${dir}" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ "${branch}" = HEAD ] || [ -z "${branch}" ]; then
    record "${name}" preflight 1 "detached HEAD -- \`git -C ${dir} switch <branch>\` first"
    return 1
  fi
  return 0
}

# Finishing an in-progress merge/rebase/etc. would carry the renovate edit into its commit.
preflight_in_progress() {
  local dir="$1" name="$2" gd="$3" what="" fix=""
  if   [ -e "${gd}/rebase-merge" ] || [ -e "${gd}/rebase-apply" ]; then
    what="a rebase";      fix="git -C ${dir} rebase --continue (or --abort)"
  elif [ -f "${gd}/MERGE_HEAD" ]; then
    what="a merge";       fix="git -C ${dir} merge --continue (or --abort)"
  elif [ -f "${gd}/CHERRY_PICK_HEAD" ]; then
    what="a cherry-pick"; fix="git -C ${dir} cherry-pick --continue (or --abort)"
  elif [ -f "${gd}/REVERT_HEAD" ]; then
    what="a revert";      fix="git -C ${dir} revert --continue (or --abort)"
  elif [ -f "${gd}/BISECT_LOG" ]; then
    what="a bisect";      fix="git -C ${dir} bisect reset"
  else
    return 0
  fi
  record "${name}" preflight 1 \
    "${what} is in progress here; finishing it would carry this edit into ITS commit -- ${fix}"
  return 1
}

# One owner for the phase: run_one and print_summary both need it.
fleet_phase() {
  if [ "${MODE}" != apply ]; then printf 'report'; return 0; fi
  if [ "${DRY_RUN}" -eq 1 ]; then printf 'plan'; return 0; fi
  printf 'apply'
}

run_one() {
  local dir="$1" name="$2" rc phase
  local -a argv=()
  local -a runner=()
  phase="$(fleet_phase)"
  if [ "${MODE}" = apply ]; then
    argv+=(--apply)
    if [ "${DRY_RUN}" -eq 1 ]; then argv+=(--dry-run); fi
  fi
  [ -n "${MANAGERS}" ] && argv+=(--managers "${MANAGERS}")
  note ""
  rule
  note "${name}  [${phase}]  ${dir}"
  rule
  preflight_repo "${dir}" "${name}" || return 0
  # --foreground keeps the child in our process group, so Ctrl-C reaches it and it rolls back.
  if [ "${BUDGET}" -gt 0 ]; then
    runner=(timeout --foreground --kill-after="${BUDGET_GRACE}s" "${BUDGET}s")
  fi
  # No pipeline, so rc is the child's; output streams because a silent run looks hung.
  ${runner[@]+"${runner[@]}"} bash "${LOCAL}" ${argv[@]+"${argv[@]}"} "${dir}"
  rc=$?
  record "${name}" "${phase}" "${rc}" "$(meaning "${phase}" "${rc}")"
  # A child killed by a signal means stop, even when this shell was not signalled.
  case "${rc}" in
    129|130|143) stop_run "${name} was stopped by a signal (rc ${rc})." "${rc}" ;;
  esac
  return 0
}

# Phase-aware: a report or plan row must not claim what only an apply does.
meaning() {
  case "$1/$2" in
    */124)    printf 'ran past the %ss budget and was killed (--timeout)' "${BUDGET}" ;;
    */129|*/130|*/143) printf 'stopped by a signal; its own output above says what its tree holds' ;;
    report/0) printf 'read; what is behind is listed above' ;;
    report/*) printf 'could not even report; nothing was read' ;;
    plan/0)   printf 'planned; every reported update would be applied' ;;
    plan/2)   printf 'planned; something would NOT be applied' ;;
    plan/*)   printf 'the plan itself was refused; nothing would be written' ;;
    apply/0)  printf 'every reported update is at its new value' ;;
    apply/2)  printf 'completed, but something was NOT applied' ;;
    apply/1)  printf 'could not complete; this tree is as it was' ;;
    *)        printf 'stopped by a signal or an unexpected exit' ;;
  esac
}

print_summary() {
  local row name phase rc what
  note ""
  rule
  note "FLEET SUMMARY -- one row per repo, and the rc is renovate-local.sh's own"
  rule
  printf '%-26s %-10s %3s  %s\n' REPO PHASE RC MEANING
  for row in ${RESULTS[@]+"${RESULTS[@]}"}; do
    IFS=$'\t' read -r name phase rc what <<<"${row}"
    printf '%-26s %-10s %3s  %s\n' "${name}" "${phase}" "${rc}" "${what}"
  done
  note ""
  print_signoff "$1"
  note ""
  note "Nothing is staged, committed or pushed. Land them in the order above."
}

# Phase-aware too; an interrupted run names what stopped it and every repo it never started.
print_signoff() {
  if [ -n "${FLEET_STOP}" ]; then
    note "INTERRUPTED: ${FLEET_STOP}"
    note_listing \
      "NOT RUN -- the run stopped before these, and nothing in them was" \
      "touched by it:" \
      -- ${NOT_RUN[@]+"${NOT_RUN[@]}"} || true
    note ""
    note "The rows above are what WAS written. Exiting ${FLEET_STOP_RC}."
    return 0
  fi
  case "${WORST}/$1" in
    0/report) note "every repo was read; what is behind each is in its table above." ;;
    0/plan)   note "every repo planned cleanly, and nothing was written anywhere." ;;
    0/*)      note "every repo finished and every reported update is at its new value." ;;
    2/*)      note "every repo finished; at least one update needs a human. Exiting 2." ;;
    *)        note "at least one repo could NOT complete. Its own tree is as it was --"
              note "the others are unaffected, which is why this run went on. Exiting 1." ;;
  esac
}

# --------------------------------------------------------------------------
cleanup() { [ -n "${GRAPH}" ] && rm -f "${GRAPH}"; return 0; }
trap cleanup EXIT

if [ "${HERE}" -eq 1 ]; then
  note "--here: this repo only, no fleet discovery."
  ORDER_PATHS=("${ROOT}"); ORDER_NAMES=("$(basename "${ROOT}")")
else
  discover_own
  discover_graph
  order_fleet
  [ "${#ORDER_PATHS[@]}" -gt 0 ] || err "no repo of ${OWNER} left to run after --only/--skip"
  refuse_duplicate_own
  if [ "${VENDORED_MODE}" -eq 1 ]; then
    order_vendored_in_place
    note "--vendored: ${ORDER_VENDORED} appended; each the ONLY checkout of a ${OWNER} repo here."
  fi
  print_plan
fi

if [ "${DRY_RUN}" -eq 1 ]; then
  note ""
  note "--dry-run over the fleet: every repo below is planned and none is"
  note "written. Each per-repo plan is renovate-local.sh's own --dry-run, which"
  note "runs the same pre-flight the real thing would."
fi

for _i in "${!ORDER_PATHS[@]}"; do
  if [ -n "${FLEET_STOP}" ]; then
    NOT_RUN+=("${ORDER_NAMES[$_i]}")
    continue
  fi
  run_one "${ORDER_PATHS[$_i]}" "${ORDER_NAMES[$_i]}"
done
print_summary "$(fleet_phase)"
[ -z "${FLEET_STOP}" ] || exit "${FLEET_STOP_RC}"
exit "${WORST}"
