#!/usr/bin/env bash
# renovate-fleet.sh over a throwaway family: the properties are about repo shapes, not the real family's names; see docs/dependency-updates.md#the-fleet
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/renovate-fixtures.sh"

FLEET="${TESTS_DIR}/../renovate-fleet.sh"

# BARE_PATH has no `timeout`, and the fleet refuses to run without one to enforce its per-repo budget.
FLEET_BIN="${WORK}/fleet-bin"
mkdir -p "${FLEET_BIN}"
for _fb in timeout date; do
  _fbsrc="$(command -v "${_fb}" 2>/dev/null || true)"
  if [ -n "${_fbsrc}" ]; then ln -sf "${_fbsrc}" "${FLEET_BIN}/${_fb}"; fi
done
FLEET_PATH="${FLEET_BIN}:${BARE_PATH}"

# _slow_git <dir> <match> <seconds>: slow `git status` in one repo, so the delay lands inside renovate-local.sh.
_slow_git() {
  mkdir -p "$1"
  {
    printf '#!/usr/bin/env bash\n_hit=0\nfor a in "$@"; do\n'
    printf '  case "${a}" in *%s*) _hit=1 ;; esac\ndone\n' "$2"
    printf 'if [ "${_hit}" = 1 ]; then\n  for a in "$@"; do\n'
    printf '    if [ "${a}" = status ]; then sleep %s; break; fi\n  done\nfi\n' "$3"
    printf 'exec "%s" "$@"\n' "$(command -v git)"
  } > "$1/git"
  chmod +x "$1/git"
}

# UP (submodule sources) sits outside FAM so the fleet cannot mistake it for a member.
FAM="${WORK}/fam"
UP="${WORK}/up"
mkdir -p "${FAM}" "${UP}"

# _fam_repo <parent> <name> <origin url>: a checkout with a manifest the injected report updates.
_fam_repo() {
  local d
  d="$(_init_repo "$1/$2")"
  git -C "${d}" remote add origin "$3"
  _plant_file "${d}" pubspec.yaml 'name: fixture\ndependencies:\n  http: 1.1.0\n'
  printf '%s' "${d}"
}

# Same without `origin`, so the repo has no identity; an empty <remote> means no remotes at all.
_fam_repo_norigin() {
  local d
  d="$(_init_repo "$1/$2")"
  [ -z "${3:-}" ] || git -C "${d}" remote add "$3" "https://example.invalid/fam/$2.git"
  _plant_file "${d}" pubspec.yaml 'name: fixture\ndependencies:\n  http: 1.1.0\n'
  printf '%s' "${d}"
}

# _vendor <superproject> <path> <source> <origin url>: the real remote url makes a vendored copy share its checkout's identity.
_vendor() {
  _add_sub "$1" "$3" "$2"
  git -C "$1/$2" remote set-url origin "$4"
  _commit "$1"
}

HUB_URL="https://example.invalid/fam/hub.git"
ONLY_URL="https://example.invalid/fam/vendored-only.git"

_fam_repo "${UP}" hub "${HUB_URL}" >/dev/null
_fam_repo "${UP}" vendored-only "${ONLY_URL}" >/dev/null

HUB="$(_fam_repo "${FAM}" hub "${HUB_URL}")"
# https and ssh spellings of one hub: a fleet keyed on raw urls would count it twice.
CA="$(_fam_repo "${FAM}" consumer-a "https://example.invalid/fam/consumer-a.git")"
CB="$(_fam_repo "${FAM}" consumer-b "git@example.invalid:fam/consumer-b.git")"
# Somebody else's repo in the same directory; (F1) asserts the fleet never runs it.
_fam_repo "${FAM}" stranger "https://example.invalid/other/stranger.git" >/dev/null
# ...and the two the fleet cannot PLACE at all.
_fam_repo_norigin "${FAM}" norem "" >/dev/null
_fam_repo_norigin "${FAM}" upstreamonly upstream >/dev/null

_vendor "${CA}" third_party/hub "${UP}/hub" "${HUB_URL}"
_vendor "${CA}" third_party/only "${UP}/vendored-only" "${ONLY_URL}"
_vendor "${CB}" third_party/hub "${UP}/hub" "git@example.invalid:fam/hub.git"

# RUN_FLEET_* knobs are passed as `NAME=value _fleet ...` so each resets itself, as in renovate-fixtures.sh's _run.
_fleet() {
  local root="$1"
  shift
  OUT="$(PATH="${RUN_FLEET_PATH:-${FLEET_PATH}}" PREFLIGHT_PYTHON="${PY_ABS}" \
         RENOVATE_LOCAL_REPORT="${RUN_FLEET_REPORT:-${A_REPORT}}" \
         RENOVATE_LOCAL_CONFIG="${RUN_FLEET_CONFIG:-${CONFIG}}" \
         bash "${FLEET}" --managers "${RUN_FLEET_MANAGERS:-pub}" "$@" "${root}" 2>&1)"
  RC=$?
  return 0
}

# Summary table rows only: each repo's banner line also starts with its name.
_rows() {
  printf '%s\n' "${OUT}" | sed -n '/^REPO  */,/^$/p' | tail -n +2 | grep -c . || true
}
_row_rc() {
  printf '%s\n' "${OUT}" | sed -n '/^REPO  */,/^$/p' \
    | sed -n "s/^$1  *[a-z]*  *\([0-9][0-9]*\) .*/\1/p"
}

# The order the summary table lists repos in, as one line.
_order() {
  printf '%s' "$(printf '%s\n' "${OUT}" \
    | sed -n '/^run order/,/^$/p' | sed -n 's/^ *[0-9]*\. *\([^ ]*\).*/\1/p' | tr '\n' ' ')"
}

t_case "(F1) the fleet is FOUND, not written down -- and stops at the owner"
_fleet "${CA}"
t_assert_eq "0" "${RC}" "a report run over the fleet must succeed"
t_assert_contains "${OUT}" "same owner as    : example.invalid/fam" \
  "the owner is read from the root's own remote"
t_assert_contains "${OUT}" "hub" "the hub is a member"
t_assert_contains "${OUT}" "consumer-b" "and so is the repo the caller did not name"
t_assert_fails grep -q '^ *[0-9]*\. *stranger' <<<"${OUT}"

t_case "(F2) ORDER: a repo runs after every fleet repo it vendors"
t_assert_eq "hub consumer-a consumer-b " "$(_order)" \
  "the hub first, because a consumer bumped before it points at nothing"

t_case "(F3) one repository, two url spellings, ONE member"
t_assert_eq "1" "$(printf '%s\n' "${OUT}" | grep -c '^ *[0-9]*\. *hub ')" \
  "hub appears exactly once in the run order"

t_case "(F4) the same repo at several paths: updated once, the copies NAMED"
t_assert_contains "${OUT}" "THE SAME REPO, CHECKED OUT AGAIN" "the answer is stated"
t_assert_contains "${OUT}" "consumer-a/third_party/hub" "and every copy is named"
t_assert_contains "${OUT}" "consumer-b/third_party/hub" "every one of them"
t_assert_contains "${OUT}" "vendored by consumer-a" "with the repo whose pointer moves it"
t_assert_contains "${OUT}" "git submodule update" "and what brings the copy to the pointer"
t_assert_eq "3" "$(_rows)" \
  "and the summary has one row per member, not one per checkout"

t_case "(F4b) the heading does not promise more than the tool keeps"
# --apply's `git submodule update --remote` does check out inside the vendored tree.
t_assert_fails grep -q 'NONE of them is written' <<<"${OUT}"
t_assert_contains "${OUT}" "No update is APPLIED in" "what is true is what it says"
t_assert_contains "${OUT}" "does check the new commit out inside the copy" \
  "and the pointer move is named as the write it is"

t_case "(F5) a repo of yours with NO own checkout is named, not silently skipped"
t_assert_contains "${OUT}" "no OWN checkout of them" "the case has its own heading"
t_assert_contains "${OUT}" "example.invalid/fam/vendored-only" "naming the repo"
t_assert_contains "${OUT}" "git clone" "and saying what to do about it"

t_case "(F5b) a sibling the fleet cannot PLACE is named too"
# A checkout without an `origin` remote must be named, not silently skipped.
t_assert_contains "${OUT}" "identity here IS \`remote.origin.url\`" \
  "the case has its own heading, saying what it looked for"
t_assert_contains "${OUT}" "norem  (remotes here: none at all)" \
  "a checkout with no remotes at all is named, with what it does have"
t_assert_contains "${OUT}" "upstreamonly  (remotes here: upstream" \
  "and so is one whose remote is called something else"
t_assert_contains "${OUT}" "remote add origin" "with what would bring it in"
t_assert_fails grep -q '^ *[0-9]*\. *norem' <<<"${OUT}"
t_assert_contains "${OUT}" "belonging to somebody else" \
  "and somebody else's checkout beside it is named rather than merely absent"
t_assert_contains "${OUT}" "stranger  is example.invalid/other/stranger" "by name"

t_case "(F6) from ANY member, the fleet is the same fleet"
_fleet "${HUB}"
t_assert_eq "hub consumer-a consumer-b " "$(_order)" "starting at the hub"
_fleet "${CB}"
t_assert_eq "hub consumer-a consumer-b " "$(_order)" "starting at a consumer"

t_case "(F6b) from INSIDE a vendored checkout, the fleet is still the fleet"
_fleet "${CA}/third_party/hub"
t_assert_eq "hub consumer-a consumer-b " "$(_order)" \
  "the run climbs to the outermost superproject first"

t_case "(F7) --here is the one repo and no fleet at all"
_fleet "${CA}" --here
t_assert_eq "0" "${RC}" "it must still succeed"
t_assert_contains "${OUT}" "this repo only, no fleet discovery" "and say so"
t_assert_fails grep -q 'run order' <<<"${OUT}"
t_assert_eq "1" "$(_rows)" "one summary row"

t_case "(F8) --only and --skip narrow it, and the order survives"
_fleet "${CA}" --only hub,consumer-b
t_assert_eq "hub consumer-b " "$(_order)" "--only keeps the order"
_fleet "${CA}" --skip consumer-a
t_assert_eq "hub consumer-b " "$(_order)" "--skip removes exactly one"

# Failure isolation, the requirement the summary exists for
t_case "(F9) a repo that FAILS does not stop the others, and the summary says which"
printf 'killed mid-apply\n' > "$(git -C "${CB}" rev-parse --absolute-git-dir)/renovate-local-inflight"
_fleet "${CA}"
t_assert_eq "1" "${RC}" "the fleet's own rc is the worst of its repos"
t_assert_contains "${OUT}" "consumer-b" "the failing repo is in the table"
t_assert_contains "${OUT}" "preflight" "with the PHASE it failed in"
t_assert_contains "${OUT}" "was killed" "and the reason"
t_assert_contains "${OUT}" "hub" "and the repos that ran are still there"
t_assert_eq "0" "$(_row_rc hub)" "hub still ran, and still passed"
t_assert_eq "1" "$(_row_rc consumer-b)" "and the one that could not is the one that says 1"
rm -f "$(git -C "${CB}" rev-parse --absolute-git-dir)/renovate-local-inflight"

t_case "(F9b) a DETACHED head is a refusal, because this tool leaves you to commit"
git -C "${CB}" checkout --quiet --detach HEAD
_fleet "${CA}"
t_assert_eq "1" "${RC}" "the fleet reports the worst rc"
t_assert_contains "${OUT}" "detached HEAD" "naming the reason"
t_assert_contains "${OUT}" "switch <branch>" "and how to fix it"
git -C "${CB}" checkout --quiet main

# _mid_git <repo> <branch> <operation>: conflicting edits leave <operation> in progress; _end_mid_git aborts it.
_mid_git() {
  _plant_file "$1" README.md 'base\n'
  git -C "$1" checkout --quiet -b "$2"
  _plant_file "$1" README.md 'theirs\n'
  git -C "$1" checkout --quiet main
  _plant_file "$1" README.md 'ours\n'
  git -C "$1" -c user.email=t@t -c user.name=t "$3" "$2" >/dev/null 2>&1
}

_end_mid_git() {
  git -C "$1" "$3" --abort >/dev/null 2>&1
  git -C "$1" checkout --quiet main
  git -C "$1" branch -qD "$2" >/dev/null 2>&1
}

# _refused_mid <what git calls it> <the command that ends it>
_refused_mid() {
  t_assert_eq "1" "${RC}" "the fleet reports it could not complete"
  t_assert_eq "1" "$(_row_rc consumer-b)" "as the repo's own row"
  t_assert_contains "${OUT}" "$1 is in progress here" "naming the state"
  t_assert_contains "${OUT}" "$2" "and the command that ends it"
  t_assert_eq "  http: 1.1.0" "$(_pub "${CB}" 3)" "and nothing was applied into it"
}

t_case "(F9c) a MERGE in progress is a refusal, and nothing is applied into it"
# Applying mid-merge would let the next `git commit -a` carry the renovate edit into that merge.
_mid_git "${CB}" side merge
t_assert_ok test -f "$(git -C "${CB}" rev-parse --absolute-git-dir)/MERGE_HEAD"
t_assert_eq "main" "$(git -C "${CB}" rev-parse --abbrev-ref HEAD)" \
  "HEAD is on a branch, so the detached-HEAD check cannot catch this"
# --only: (F11) reads the other members back as untouched.
_fleet "${CA}" --apply --only consumer-b
_refused_mid "a merge" "merge --continue"
_end_mid_git "${CB}" side merge

t_case "(F9d) mid-REBASE, the advice is the rebase's, not 'switch <branch>'"
# `git switch <branch>` in the middle of a rebase abandons it.
_mid_git "${CB}" side2 rebase
_fleet "${CA}" --apply --only consumer-b
_refused_mid "a rebase" "rebase --continue"
t_assert_fails grep -q 'switch <branch>' <<<"${OUT}"
_end_mid_git "${CB}" side2 rebase

t_case "(F9e) a cherry-pick and a revert are the same refusal, with their own fix"
# Driven for real, not by planting a state file, so the path git writes is the path preflight reads.
for _op in cherry-pick revert; do
  _mid_git "${CB}" "side-${_op}" "${_op}"
  _fleet "${CA}" --apply --only consumer-b
  _refused_mid "a ${_op}" "${_op} --continue"
  _end_mid_git "${CB}" "side-${_op}" "${_op}"
done

t_case "(F9f) a BISECT detaches HEAD, and the fix is the bisect's"
# A bisect has no *_HEAD file and detaches HEAD, and `git switch <branch>` would throw it away.
git -C "${CB}" bisect start >/dev/null 2>&1
git -C "${CB}" bisect bad >/dev/null 2>&1
git -C "${CB}" bisect good "$(git -C "${CB}" rev-list --max-parents=0 HEAD | tail -1)" >/dev/null 2>&1
t_assert_ok test -f "$(git -C "${CB}" rev-parse --absolute-git-dir)/BISECT_LOG"
_fleet "${CA}" --apply --only consumer-b
_refused_mid "a bisect" "bisect reset"
t_assert_fails grep -q 'switch <branch>' <<<"${OUT}"
git -C "${CB}" bisect reset >/dev/null 2>&1

t_case "(F10) 1 beats 2 beats 0 -- 'broken' is not the same answer as 'needs a human'"
RUN_FLEET_CONFIG="${REFUSE_CONFIG}" _fleet "${CA}" --apply --dry-run
t_assert_eq "2" "${RC}" "every repo completed and something was not applied"
t_assert_contains "${OUT}" "needs a human" "and the summary says which answer this is"

t_case "(F11) --dry-run prints the whole plan and changes nothing, anywhere"
git -C "${HUB}" diff --quiet HEAD
_fleet "${CA}" --apply --dry-run
t_assert_eq "0" "${RC}" "the plan must print"
t_assert_contains "${OUT}" "run order" "the fleet plan"
t_assert_contains "${OUT}" "every repo below is planned and none is" "said plainly"
t_assert_contains "${OUT}" "[plan]" "and each repo is marked as planned, not applied"
t_assert_contains "${OUT}" "nothing was written anywhere" \
  "the sign-off is the PLAN's, not a claim that something was applied"
t_assert_eq "0" "$(t_rc git -C "${HUB}" diff --quiet HEAD)" "the hub is untouched"
t_assert_eq "0" "$(t_rc git -C "${CA}" diff --quiet --ignore-submodules=dirty HEAD)" \
  "and so is the consumer the run started from"
t_assert_eq "  http: 1.1.0" "$(_pub "${CA}" 3)" "no manifest moved"
t_assert_eq "  http: 1.1.0" "$(_pub "${HUB}" 3)" "in any repo"

t_case "(F12) --apply moves the gitlink, and Renovate applies in no vendored copy"
# Both halves in the report so apply_submodules really runs; `insteadOf` keeps the copy's identity url yet fetchable.
GITLINK_REPORT="${WORK}/fleet-gitlink.json"
_report_mixed "${GITLINK_REPORT}" \
  git-submodules .gitmodules third_party/hub main main \
  pub pubspec.yaml http 1.1.0 1.6.0
git -C "${CA}/third_party/hub" config "url.${UP}/hub.insteadOf" "${HUB_URL}"
_VHUB_BEFORE="$(git -C "${CA}/third_party/hub" rev-parse HEAD)"
_plant_file "${UP}/hub" NEWFILE.txt 'moved on\n'
RUN_FLEET_REPORT="${GITLINK_REPORT}" RUN_FLEET_MANAGERS=pub,git-submodules \
  _fleet "${CA}" --apply
t_assert_eq "  http: 1.6.0" "$(_pub "${HUB}" 3)" "the hub's own checkout moved"
t_assert_eq "  http: 1.6.0" "$(_pub "${CA}" 3)" "and the consumer's"
t_assert_eq "  http: 1.1.0" "$(_pub "${CA}/third_party/only" 3)" \
  "a vendored copy no gitlink update names is not written at all"
t_assert_fails test "${_VHUB_BEFORE}" = "$(git -C "${CA}/third_party/hub" rev-parse HEAD)"
t_assert_ok test -f "${CA}/third_party/hub/NEWFILE.txt"
t_assert_eq "  http: 1.1.0" "$(_pub "${CA}/third_party/hub" 3)" \
  "the pointer moved the copy, and Renovate applied nothing inside it"
git -C "${CA}" checkout --quiet -- pubspec.yaml
git -C "${HUB}" checkout --quiet -- pubspec.yaml
git -C "${CA}" submodule update --quiet --checkout -- third_party/hub 2>/dev/null || true

# Adversarial shapes, each in its own family because the one above deliberately lacks them
t_case "(F13) Ctrl-C STOPS the fleet -- it does not consume one repo and go on"
# SIGINT goes to the process group, as a terminal's Ctrl-C does.
INTFAM="${WORK}/intfam"
mkdir -p "${INTFAM}"
for _n in r1 r2 r3 r4 r5 r6; do
  _fam_repo "${INTFAM}" "${_n}" "https://example.invalid/int/${_n}.git" >/dev/null
done
_slow_git "${WORK}/slow-int" /intfam/ 3
INT_LOG="${WORK}/int.log"
: > "${INT_LOG}"
# Without `set -m` the background job inherits SIGINT as ignored, and the fleet's INT trap never installs.
set -m
PATH="${WORK}/slow-int:${FLEET_PATH}" PREFLIGHT_PYTHON="${PY_ABS}" \
  RENOVATE_LOCAL_REPORT="${A_REPORT}" RENOVATE_LOCAL_CONFIG="${CONFIG}" \
  bash "${FLEET}" --managers pub --apply "${INTFAM}/r1" > "${INT_LOG}" 2>&1 &
INT_JOB=$!
set +m
_int_n=0
while [ "${_int_n}" -lt 900 ]; do
  grep -q 'r1  \[apply\]' "${INT_LOG}" 2>/dev/null && break
  kill -0 "${INT_JOB}" 2>/dev/null || break
  sleep 0.1
  _int_n=$((_int_n + 1))
done
t_assert_ok grep -q 'r1  \[apply\]' "${INT_LOG}"
kill -INT -- "-${INT_JOB}" 2>/dev/null || true
wait "${INT_JOB}"
RC=$?
OUT="$(cat "${INT_LOG}")"
t_assert_eq "130" "${RC}" "SIGINT exits 130, not 0 and not the worst per-repo rc"
t_assert_contains "${OUT}" "STOPPING: SIGINT" "and says what stopped it"
t_assert_contains "${OUT}" "INTERRUPTED" "in the summary too"
t_assert_contains "${OUT}" "NOT RUN" "which names what it never started"
t_assert_contains "${OUT}" "r6" "including the last one"
for _n in r3 r4 r5 r6; do
  t_assert_eq "  http: 1.1.0" "$(_pub "${INTFAM}/${_n}" 3)" \
    "${_n} was never started, so its manifest is as it was"
  t_assert_eq "" "$(git -C "${INTFAM}/${_n}" status --porcelain)" \
    "${_n}'s tree is clean"
done

t_case "(F14) TWO OWN CHECKOUTS of one repository: refused, not written twice"
# A second clone or a `git worktree` of one repository has this shape.
DUPFAM="${WORK}/dupfam"
mkdir -p "${DUPFAM}"
DUP_URL="https://example.invalid/dup/hub.git"
_fam_repo "${DUPFAM}" hub "${DUP_URL}" >/dev/null
_fam_repo "${DUPFAM}" hub2 "${DUP_URL}" >/dev/null
DCA="$(_fam_repo "${DUPFAM}" consumer "https://example.invalid/dup/consumer.git")"
_fleet "${DCA}" --apply
t_assert_eq "1" "${RC}" "the run is refused"
t_assert_contains "${OUT}" "TWO OWN CHECKOUTS OF ONE REPOSITORY" "by name"
t_assert_contains "${OUT}" "${DUPFAM}/hub " "naming the first path"
t_assert_contains "${OUT}" "${DUPFAM}/hub2" "and the second"
t_assert_contains "${OUT}" "--skip" "and what the human says back"
t_assert_eq "  http: 1.1.0" "$(_pub "${DUPFAM}/hub" 3)" "and nothing was written"
t_assert_eq "  http: 1.1.0" "$(_pub "${DUPFAM}/hub2" 3)" "in either of them"
t_assert_eq "  http: 1.1.0" "$(_pub "${DCA}" 3)" "or anywhere else in the fleet"

t_case "(F14b) --skip settles it, and then exactly one of the two is written"
_fleet "${DCA}" --apply --skip hub2
t_assert_eq "0" "${RC}" "the run goes ahead"
t_assert_eq "  http: 1.6.0" "$(_pub "${DUPFAM}/hub" 3)" "the checkout that was kept"
t_assert_eq "  http: 1.1.0" "$(_pub "${DUPFAM}/hub2" 3)" "and only that one"

t_case "(F15) an UNINITIALISED nested submodule cannot silently break the order"
# acon vendors zdep, whose hub is de-initialised, as in a clone without `submodule update --init --recursive`.
NFAM="${WORK}/nfam"
NUP="${WORK}/nup"
mkdir -p "${NFAM}" "${NUP}"
N_HUB="https://example.invalid/n/hub.git"
N_ZDEP="https://example.invalid/n/zdep.git"
_fam_repo "${NUP}" hub "${N_HUB}" >/dev/null
NUZ="$(_fam_repo "${NUP}" zdep "${N_ZDEP}")"
_vendor "${NUZ}" tp/hub "${NUP}/hub" "${N_HUB}"
_fam_repo "${NFAM}" hub "${N_HUB}" >/dev/null
NZ="$(_fam_repo "${NFAM}" zdep "${N_ZDEP}")"
_vendor "${NZ}" tp/hub "${NUP}/hub" "${N_HUB}"
NAC="$(_fam_repo "${NFAM}" acon "https://example.invalid/n/acon.git")"
_vendor "${NAC}" tp/zdep "${NUZ}" "${N_ZDEP}"
git -C "${NAC}/tp/zdep" submodule deinit -f tp/hub >/dev/null 2>&1
t_assert_fails test -e "${NAC}/tp/zdep/tp/hub/.git"
_fleet "${NAC}"
t_assert_eq "hub zdep acon " "$(_order)" \
  "acon vendors zdep, so acon runs after it -- read off the fleet's own copy of zdep"
t_assert_contains "${OUT}" "UNINITIALISED SUBMODULE" "and the hole is named"
t_assert_contains "${OUT}" "acon/tp/zdep/tp/hub" "with the path that is missing"
t_assert_contains "${OUT}" "submodule update --init --recursive" "and what fills it"

t_case "(F16) a per-repo BUDGET, so one repo cannot hold the fleet"
# `--timeout 5`, not 1, survives a loaded runner; `slow` sleeps 20s either way.
SFAM="${WORK}/sfam"
mkdir -p "${SFAM}"
for _n in aaa slow zzz; do
  _fam_repo "${SFAM}" "${_n}" "https://example.invalid/s/${_n}.git" >/dev/null
done
_slow_git "${WORK}/slow-budget" /sfam/slow 20
RUN_FLEET_PATH="${WORK}/slow-budget:${FLEET_PATH}" \
  _fleet "${SFAM}/aaa" --apply --timeout 5
t_assert_eq "1" "${RC}" "a repo that ran out of time is 'could not complete'"
t_assert_eq "124" "$(_row_rc slow)" "and its row carries timeout's own rc"
t_assert_contains "${OUT}" "budget" "said in words as well as a number"
t_assert_eq "0" "$(_row_rc aaa)" "the repo before it still ran"
t_assert_eq "0" "$(_row_rc zzz)" "and so did the one after -- the fleet went on"
t_assert_eq "  http: 1.6.0" "$(_pub "${SFAM}/zzz" 3)" "really ran, not just a row"

t_case "(F16b) the budget is a number, and turning it off is something you TYPE"
_fleet "${HUB}" --timeout abc
t_assert_eq "1" "${RC}" "a non-number is refused"
t_assert_contains "${OUT}" "whole seconds" "with what it wanted"
_fleet "${HUB}" --timeout 0
t_assert_eq "0" "${RC}" "0 is allowed"
t_assert_contains "${OUT}" "OFF (--timeout 0)" \
  "and the plan says the budget is off rather than printing a limit it has not got"
_fleet "${HUB}"
t_assert_contains "${OUT}" "per-repo budget  : 600s per repo" "the default is printed too"

t_summary
