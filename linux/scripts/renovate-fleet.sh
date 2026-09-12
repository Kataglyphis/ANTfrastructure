#!/usr/bin/env bash
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# renovate-fleet.sh -- renovate-local.sh over EVERY repo the family has, from
# the top or from any one of them, in an order the results can be landed in.
# What it finds, how it orders it, what it does about the same repo checked out
# eight times, and its exit codes: docs/dependency-updates.md#the-fleet
set -uo pipefail

# err/note/note_listing/refuse_listing, the same four renovate-local.sh reports
# through: a refusal that reads differently in the two tools is two contracts.
# The argument is the name a fatal message is signed with.
# shellcheck source=renovate-say.sh
. "$(dirname "${BASH_SOURCE[0]}")/renovate-say.sh" renovate-fleet.sh \
  || { printf 'renovate-fleet.sh: cannot load renovate-say.sh beside me\n' >&2; exit 1; }

rule() { note "=============================================================="; }

# The budget, as the plan prints it -- a function, because an inline `&&`/`||`
# pair inside a heading is a place to get a fact backwards.
budget_text() {
  if [ "${BUDGET}" -gt 0 ]; then printf '%ss per repo' "${BUDGET}"; return 0; fi
  printf 'OFF (--timeout 0): one repo CAN hold this run for ever'
}

# The help text, in a heredoc rather than as a comment block the header sed-s
# back out: the usage IS user-facing output, and a comment that is secretly
# output cannot be shortened without silently changing the interface.
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
ONLY=""; SKIP=""; MANAGERS=""
ROOT=""
# The per-repo wall clock, in seconds. NOT a tuning knob for slow networks: the
# fleet finds every repo of the owner's beside the top, and on this machine that
# includes llvm-project, where a single `git status --porcelain` did not come
# back in 600s (measured 2026-09-11). One repo must not be able to hold the
# other six, so every repo gets a budget and the row says when it ran out.
BUDGET=600
# ...and how long after the TERM a repo gets to put its tree back before the
# KILL. renovate-local.sh rolls back on a signal; a KILL cannot be trapped, so
# this is the whole window it has.
BUDGET_GRACE=30

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)      MODE=apply ;;
    --report)     MODE=report ;;
    --dry-run)    DRY_RUN=1; MODE=apply ;;
    --here)       HERE=1 ;;
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
# A budget nothing can enforce is not a budget. `timeout` is coreutils and is on
# every Linux this tree runs on; when it is genuinely absent the human is told
# what they are choosing rather than handed a limit that silently is not one.
if [ "${BUDGET}" -gt 0 ] && ! command -v timeout >/dev/null 2>&1; then
  err "no 'timeout' on PATH, so the ${BUDGET}s per-repo budget cannot be enforced -- install coreutils, or run with --timeout 0 and accept that one repo can hold the fleet"
fi

ROOT="${ROOT:-$PWD}"
[ -d "${ROOT}" ] || err "not a directory: ${ROOT}"
ROOT="$(cd "${ROOT}" && pwd)"
git -C "${ROOT}" rev-parse --git-dir >/dev/null 2>&1 || err "not a git repo: ${ROOT}"
ROOT="$(git -C "${ROOT}" rev-parse --show-toplevel)"

# --------------------------------------------------------------------------
# Identity. One repository is checked out under several paths AND under both url
# spellings -- OrchestrANT declares ContainerHub over https, everyone else over
# git@ -- so a fleet keyed on paths or on raw urls counts it as several. The key
# is the normalised remote: host/owner/name, lowercased, no scheme, user or .git.
# KNOWN LIMIT: an ssh url with an explicit PORT turns its port into a path
# segment here. No remote in this family has one; this is where it is fixed.
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

# host/owner out of an identity: the two leading segments. What "the same owner
# as the root" means, and it is read from the ROOT's own remote rather than
# written down here -- a name list is the thing this file exists not to have.
identity_owner() { printf '%s' "$1" | cut -d/ -f1,2; }

# --------------------------------------------------------------------------
# STOPPING. Ctrl-C signals the process GROUP, so this shell and the
# renovate-local.sh it waits on both get it; bash defers the handler until that
# child returns, which is exactly the window the child needs to put its own tree
# back. What was missing until 2026-09-11 was everything after that -- there was
# no INT trap at all, the `for` loop simply went on, and a six-repo fleet
# APPLIED five more repos after the user asked it to stop.
# --------------------------------------------------------------------------
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

# --------------------------------------------------------------------------
# Discovery.
# --------------------------------------------------------------------------
# The outermost superproject of whatever the caller pointed at, so that running
# this from inside third_party/OxidANT means the same thing as running it from
# the top. That IS the owner's requirement, in their words: "von diesem
# mutterrepo aus ODER in den einzelnen subrepos".
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

# How deep the submodule walk goes. The family's deepest real chain is
# consumer -> OxidANT -> ContainerHub -> DocumANTation -> awesome-beamer, i.e.
# 4. The bound is not a tuning knob: a .gitmodules that points at an ancestor
# makes the walk run forever, and a fleet tool that hangs is worse than one
# that stops and says how deep it looked.
MAX_DEPTH=8

# Every submodule reachable from <dir>, as
# "<state><TAB><identity><TAB><abs path><TAB><the repo that vendors it>".
# state is `checkout` or `uninit`. An UNINITIALISED submodule used to be
# `continue`d, which made everything BENEATH it invisible: measured 2026-09-11
# where acon vendors zdep and zdep vendors hub, acon's de-initialised copy of
# zdep's hub took acon's rank from 2 to 1 and put acon -- which vendors zdep --
# in FRONT of zdep. A fresh clone that has not run `git submodule update --init
# --recursive` is exactly that state, and .gitmodules still carries the url, so
# the edge is kept and named and only the subtree under it is really lost.
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

# The OWN checkouts: the ones a human pushes from. A repo's own checkout is a
# directory beside the top superproject, ONE level deep, whose remote has the
# same owner as the root's. Not a name list, and not a recursive filesystem
# sweep either -- a sweep reaches the scratch clones under _ratchet/ and
# _hubgate_logs/ (six of them on this machine), and a fleet that writes into a
# scratch clone is the accident this whole file is shaped around.
discover_own() {
  local d id rem
  TOP="$(climb_to_top "${ROOT}")"
  FAMILY_DIR="$(dirname "${TOP}")"
  OWNER="$(identity_owner "$(repo_identity "${TOP}" || true)")"
  [ -n "${OWNER}" ] || err "${TOP} has no origin remote, so 'the same owner' has no meaning here; run with --here"
  for d in "${FAMILY_DIR}"/*; do
    [ -e "${d}/.git" ] || continue
    id="$(repo_identity "${d}" 2>/dev/null)" || id=""
    # COLLECTED, not dropped. This read used to end in `|| continue`, so a
    # checkout with no `origin` -- one cloned from a mirror, one whose remote is
    # called `upstream` -- appeared in no plan, no summary and no heading at all,
    # while six headings named things the fleet had deliberately not touched.
    # Measured on this machine 2026-09-11, that silently swallowed _flutter-probe.
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

# Every vendored checkout under every own checkout -- ONE walk per own repo, its
# results tagged with the own repo they came from so the ordering below can read
# the same rows instead of walking the tree a second time.
#
# Three things come out of it: where each identity is vendored (so the summary
# can NAME the copies it did not touch), which of the owner's identities have no
# own checkout at all, and the transitive fleet-dependency set of each own repo.
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
  # find_cycles reads the sets the WALK produced, before the closure below can
  # make a three-repo cycle look like a mutual pair it is not.
  find_cycles
  close_deps
  return 0
}

# One submodule, into every list it belongs in. FOUR kinds, and only the second
# is the owner's question:
#   * a copy of the vendoring repo ITSELF -- constrains no order, but is named
#   * a SECOND checkout of a repo the fleet updates in its own tree -- the
#     duplicate this file exists to answer, and an ordering constraint
#   * a repo of the owner's with NO own checkout -- named, not updated
#   * somebody else's upstream -- COUNTED, not listed: printing all of them
#     buried the seven ContainerHub copies in noise (measured over the real
#     family 2026-09-11: 56 rows, 36 of them the owner's, 20 somebody else's,
#     which is the count the tool itself prints)
classify_vendored() {
  local i="$1" state="$2" id="$3" abs="$4" owner_dir="$5"
  # A SECOND `local`: an assignment reading a name declared in the SAME `local`
  # has not taken effect yet in every shell, so `rel` would be the whole
  # absolute path in some of them and the family-relative one here (SC2318).
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
  # The dependency EDGE is recorded whether or not there is a checkout to look
  # inside: what a repo declares is the fact the order is built on, not what
  # happens to be cloned today. Only the LISTING needs a working tree.
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

# --------------------------------------------------------------------------
# ORDER. A repo runs AFTER every fleet repo it vendors: ContainerHub is pinned
# by everyone, and a consumer bumped before the hub lands points at a commit
# that does not exist yet. The rank is the number of fleet identities the repo
# vendors transitively, and sorting on it IS a topological order because
# A vendoring B makes deps(A) a strict superset of deps(B).
# Why equal ranks are not a cycle, and the honest limit no ordering can fix
# (this tool pushes nothing, so the order is the order to LAND results in):
# docs/dependency-updates.md#order
# --------------------------------------------------------------------------

# The proof above needs deps(A) to CONTAIN deps(B), and the walk cannot always
# see deps(B) -- an uninitialised submodule hides everything under it. When B is
# a fleet member the fleet holds its OWN checkout of B and has already read
# deps(B) there, so union those in to a fixpoint. What is left unknowable is an
# uninitialised copy of a repo with no own checkout: print_unplaced names it.
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

# How many identities are in a " a b c " dependency set. `wc -w` rather than a
# counting loop whose variable nothing reads.
dep_count() { printf '%s' "$1" | wc -w | tr -d ' '; }

# A vendors B and B vendors A: two repos that cannot both go second. There is no
# correct order for such a pair, so the fleet says so instead of implying its
# arbitrary choice was one.
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

# --only / --skip, by directory name. Both are commas, and a name in neither
# list is IN when --only is empty and OUT when it is not.
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

# TWO OWN CHECKOUTS OF ONE REPOSITORY. A second clone beside the first, a
# `git worktree`, a `ContainerHub-2` kept for a bisect: all three carry one
# origin, all three used to be members, and `--apply` wrote the same update into
# every one (measured 2026-09-11: `hub` and `hub2`, both rewritten, both rc 0,
# neither named anywhere). The fleet cannot know which one the human pushes
# from, and guessing is how work got lost twice -- so it refuses, by name,
# before anything is written, and --only/--skip are the answer the human gives
# back. Checked over the SELECTED set, so `--skip hub2` really does settle it.
# docs/dependency-updates.md#the-same-repo-checked-out-several-times
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

# --------------------------------------------------------------------------
# The plan, printed before anything runs and printed in FULL by --dry-run.
# --------------------------------------------------------------------------
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


# One row per repo of the owner's that has no own checkout, with HOW MANY
# vendored copies it has and one of them as an example. Listing every copy put
# 29 lines under this heading over the real family and buried the six answers in
# them; the count is the fact, the path is the pointer to look at.
NO_OWN_ROWS=()
summarise_no_own() {
  local id n first
  for id in ${NO_OWN[@]+"${NO_OWN[@]}"}; do
    n="$(printf '%s\n' ${VENDORED[@]+"${VENDORED[@]}"} | grep -c -- "is ${id}\$" || true)"
    first="$(printf '%s\n' ${VENDORED[@]+"${VENDORED[@]}"} | grep -m1 -- "is ${id}\$" || true)"
    NO_OWN_ROWS+=("${id}  (${n} vendored copy(ies), e.g. ${first%%  is *})")
  done
}

# THE DUPLICATE-CHECKOUT ANSWER, and the point of this whole file: a repo is
# UPDATED where it lives as a repository, and the POINTERS to it are moved where
# it is vendored. A vendored checkout is never a fleet member, and it is NAMED,
# because eight working trees of ContainerHub written by one --apply is how work
# got lost twice in one day. The measurements and the argument:
# docs/dependency-updates.md#the-same-repo-checked-out-several-times
print_duplicates() {
  summarise_no_own
  # This heading used to say "NONE of them is written". Renovate applies nothing
  # in a vendored copy, but moving the pointer is `git submodule update
  # --remote`, which fetches and CHECKS OUT inside that working tree: measured
  # 2026-09-11, a vendored hub went 31a4445 -> 256c4c6 and gained a tracked
  # file. A promise this tool does not keep is worse than no promise.
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

# What the fleet could NOT place, said out loud. Every heading above names
# something deliberately not touched; these three used to be the silence.
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

# --------------------------------------------------------------------------
# Running one repo, and never letting it take the others with it.
# --------------------------------------------------------------------------
RESULTS=()
WORST=0

record() {
  RESULTS+=("$(printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4")")
  case "$3" in
    0) ;;
    2) [ "${WORST}" -eq 1 ] || WORST=2 ;;
    # 1, and every rc that is not in the contract at all -- a signal, a crash.
    # Those are "could not complete", never "needs a human".
    *) WORST=1 ;;
  esac
}

# What the fleet itself checks before handing a repo to renovate-local.sh, so a
# repo that cannot be worked on is a named row rather than a wall of output.
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
  # A DETACHED HEAD is a refusal on purpose: this tool commits nothing, so the
  # human commits -- and a commit made on a detached HEAD is the work that gets
  # lost. It is checked LAST because a rebase also detaches HEAD, and
  # "switch <branch> first" is actively wrong advice in the middle of one.
  branch="$(git -C "${dir}" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ "${branch}" = HEAD ] || [ -z "${branch}" ]; then
    record "${name}" preflight 1 "detached HEAD -- \`git -C ${dir} switch <branch>\` first"
    return 1
  fi
  return 0
}

# A merge, cherry-pick, revert, rebase or bisect that is still RUNNING. HEAD is
# on a branch and the git dir is nameable, so nothing above catches it -- and
# measured 2026-09-11 the fleet applied straight into a conflicted merge (UU
# README.md, MERGE_HEAD present, HEAD on `main`), rc 0, merge still in progress
# afterwards. The next `git commit -a` finishes THAT merge and carries the
# renovate edit into it, under the merge's own message.
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

# Which phase this whole run is in: report, plan (--apply --dry-run) or apply.
# One owner, because run_one and print_summary both need it and two derivations
# of one fact drift.
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
  # --foreground is load-bearing: without it `timeout` puts the child in a NEW
  # process group, and the Ctrl-C that signals THIS group would never reach
  # renovate-local.sh -- the repo would keep writing while the fleet tried to
  # stop. With it the child stays in the group and rolls its own tree back.
  if [ "${BUDGET}" -gt 0 ]; then
    runner=(timeout --foreground --kill-after="${BUDGET_GRACE}s" "${BUDGET}s")
  fi
  # No pipeline: `rc=$?` after one would report the last stage. The output is
  # printed as it comes because a fleet run is long and a silent one is
  # indistinguishable from a hung one.
  ${runner[@]+"${runner[@]}"} bash "${LOCAL}" ${argv[@]+"${argv[@]}"} "${dir}"
  rc=$?
  record "${name}" "${phase}" "${rc}" "$(meaning "${phase}" "${rc}")"
  # A repo killed by a signal is a stop request even when this shell was not
  # signalled itself -- which is the case when somebody kills the child, or when
  # a kill reached only part of the group.
  case "${rc}" in
    129|130|143) stop_run "${name} was stopped by a signal (rc ${rc})." "${rc}" ;;
  esac
  return 0
}

# The rc says the same thing in every phase; what it MEANS for the tree does
# not. A report writes nothing, so "every reported update is at its new value"
# would be a claim about an apply that never happened -- and a summary row a
# reader has to translate is a summary row that gets misread.
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

# The all-green line is phase-aware for the same reason the rows are: a plan
# run that signs off with "every update is applied" is a summary the reader
# has to translate, and a summary that needs translating gets misread. An
# INTERRUPTED run gets neither: it says what stopped it and names every repo it
# never started, because "nothing anywhere says you interrupted this and I
# carried on" was the whole defect.
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
