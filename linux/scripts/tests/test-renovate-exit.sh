#!/usr/bin/env bash
# How a renovate-local.sh run ENDS: the exit code a caller branches on, and what
# a signal leaves behind. The world these cases run in is renovate-fixtures.sh
# beside this file; the locator's verdicts are test-renovate-local.sh and the
# read-back audit is test-renovate-audit.sh.

# Both halves are defects MEASURED on 2026-09-10, and both were invisible
# because the run PRINTED the right thing: every plan-time refusal exited 0,
# which to a caller is byte-identical to a repo with nothing behind; and a
# signal was treated as a clean exit, leaving the manifest rewritten, the
# lockfile half-refreshed and the only copies of both already deleted.
# docs/dependency-updates.md#the-mechanics-of-a-refusal
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/renovate-fixtures.sh"

# --------------------------------------------------------------------------
# 0 / 1 / 2 -- and the difference between the two non-zero ones
# --------------------------------------------------------------------------
t_case "(X1) a repo with nothing behind exits 0"
X1="$(_plant x1 pubspec.yaml 'name: fixture\ndependencies:\n  http: 1.1.0\n')"
EMPTY_REPORT="${WORK}/empty.json"
printf '{"repositories":{"local":{"packageFiles":{}}}}\n' > "${EMPTY_REPORT}"
_run "${X1}" "${EMPTY_REPORT}" --apply --managers pub
t_assert_eq "0" "${RC}" "nothing behind, nothing refused, nothing to explain"
t_assert_contains "${OUT}" "up to date" "and it says so"

# The other two zeroes -- a run that APPLIES everything, and a re-run over the
# same report reporting "already applied" -- are case (a) of
# test-renovate-local.sh, which asserts rc 0 on both passes. Planting that
# fixture a second time here would be the copy the duplication gate catches, and
# it would prove nothing this file does not already get from (X1).

# The case that named the whole problem: one update, refused, and until
# 2026-09-10 indistinguishable from (X1) at the exit code.
t_case "(X3) a plan-time refusal exits 2, and says how many it did not write"
X3="$(_plant x3 pubspec.yaml 'name: fixture\ndependencies: &deps\n  http: 1.1.0\ndependency_overrides:\n  http: 1.1.0\n')"
_run "${X3}" "${A_REPORT}" --apply --managers pub
t_assert_eq "2" "${RC}" "a refusal is not a pass, and 0 said it was"
t_assert_contains "${OUT}" "NOT EVERYTHING WAS APPLIED: 1 reported update(s)" \
  "the last line counts them, so the code and the text agree"
t_assert_eq "  http: 1.1.0" "$(_pub "${X3}" 3)" "and nothing was written"

# The fourth refusal class -- the repo's own Renovate config sending an update
# to a human (dependencyDashboardApproval) -- is the SAME fact to a caller: the
# report named it and this run did not write it. It is asserted where that case
# already lives, in test-renovate-local.sh, rather than planted a second time
# here.

# A run that ABORTS is a different fact from a run that refused one update, and
# the two codes are what keep them apart: 1 means the tree is where it started
# and a human fixes the cause; 2 means the tree is consistent and a human
# applies what is left.
t_case "(X5) a run that cannot complete exits 1, never 2"
X5="$(_plant x5 pubspec.yaml 'name: fixture\ndependencies:\n  http: 1.1.0\n')"
printf 'name: fixture\ndependencies:\n  http: 1.1.0\n# edited by hand\n' > "${X5}/pubspec.yaml"
_run "${X5}" "${A_REPORT}" --apply --managers pub
t_assert_eq "1" "${RC}" "the whole run aborted; nothing was even attempted"
t_assert_contains "${OUT}" "these paths have local changes" "and it says why"

# One plan, two files, one of them refused: the other still applies, and the run
# still reports that it did not do everything. Partial success is not success.
_mixed_repo() {
  local d
  d="$(_repo "$1")"
  printf 'name: fixture\ndependencies:\n  http: 1.1.0\n' > "${d}/pubspec.yaml"
  mkdir -p "${d}/pkg"
  printf 'name: fixture\ndependencies:\n  http: 1.1.0\ndependency_overrides:\n  http: 1.1.0\n' \
    > "${d}/pkg/pubspec.yaml"
  _commit "${d}"
  printf '%s' "${d}"
}
MIXED_REPORT="${WORK}/mixed.json"
_report_pair "${MIXED_REPORT}" pub http 1.1.0 1.6.0 pubspec.yaml pkg/pubspec.yaml

t_case "(X6) one applied and one refused: the applied one lands, the code is 2"
X6="$(_mixed_repo x6)"
_run "${X6}" "${MIXED_REPORT}" --apply --managers pub
t_assert_eq "2" "${RC}" "not everything was applied, so not 0"
t_assert_eq "  http: 1.6.0" "$(_pub "${X6}" 3)" "the file that could be written was"
t_assert_eq "  http: 1.1.0" "$(_line "${X6}/pkg/pubspec.yaml" 3)" \
  "the file that could not is untouched"
t_assert_contains "${OUT}" "NOT EVERYTHING WAS APPLIED" "and the run says so"

# The refusal classes are four -- the parser or locator would not place it, the
# repo's config sends it to a human, a submodule declares no `branch =`, a
# submodule is not declared here at all -- and they meet in ONE counter. This is
# the class furthest from the others: no manifest, no plan, no file at all.
t_case "(X6b) a submodule reported behind that this repo does not declare is 2 too"
X6B="$(_repo x6b)"
printf 'placeholder\n' > "${X6B}/README"
_commit "${X6B}"
X6B_REPORT="${WORK}/x6b.json"
_report "${X6B_REPORT}" git-submodules .gitmodules sub main main
_run "${X6B}" "${X6B_REPORT}" --apply --managers git-submodules
t_assert_eq "2" "${RC}" "nothing was applied, and something was reported behind"
t_assert_contains "${OUT}" "this repo does not declare" "and the run says which class"

t_case "(X7) --dry-run exits what --apply will exit, on the same plan"
X7="$(_mixed_repo x7)"
_run "${X7}" "${MIXED_REPORT}" --apply --dry-run --managers pub
t_assert_eq "2" "${RC}" "a reviewer's exit code is the real run's exit code"
t_assert_eq "  http: 1.1.0" "$(_pub "${X7}" 3)" "--dry-run still wrote nothing"
_run "${X7}" "${MIXED_REPORT}" --apply --managers pub
t_assert_eq "2" "${RC}" "and the real run agrees"

# --------------------------------------------------------------------------
# A signal is not a clean exit
# --------------------------------------------------------------------------
# TMPDIR is the whole observation. Every copy this script takes beside a run is
# an `mktemp -d`, so pointing TMPDIR at an empty directory of our own makes
# "were the backups deleted?" a thing a case can READ rather than infer.
SIG_TMP="${WORK}/sig-tmp"
SIG_PIDFILE="${WORK}/sig-pid"
SIG_STUBS="${WORK}/sig-stubs"
mkdir -p "${SIG_TMP}" "${SIG_STUBS}"

# A lock tool that gets part way and is then interrupted, which is the state a
# Ctrl-C or a CI cancel actually finds: the manifests written, one lockfile
# half-written, minutes of `cargo update` still to go. It signals the RUN rather
# than the suite waiting on a timer, so the case is deterministic and needs no
# process-group tooling: the pid arrives in a file the moment the run is
# backgrounded, and the short sleep only orders the delivery.
cat > "${SIG_STUBS}/cargo" <<'STUB'
#!/usr/bin/env bash
printf 'half\n' >> Cargo.lock
while [ ! -s "${RL_SIGNAL_PIDFILE}" ]; do sleep 0.05; done
kill -"${RL_SIGNAL_SIG}" "$(cat "${RL_SIGNAL_PIDFILE}")"
sleep 0.5
STUB
chmod +x "${SIG_STUBS}/cargo"

# A launcher that hands the run SIGINT and SIGQUIT back at their DEFAULTS.
#
# Measured while writing (X8): a shell that starts a command with `&` gives it
# SIGINT and SIGQUIT set to SIG_IGN -- POSIX requires that of an asynchronous
# command -- and bash cannot trap a signal that was ignored on entry. So the
# first cut of this suite watched its own launcher swallow the signal and
# reported the script as broken. A real Ctrl-C reaches a foreground run, which
# is the disposition this restores. Nothing else about the run changes.
SIGSAFE="${WORK}/sigsafe.py"
cat > "${SIGSAFE}" <<'PY'
import os
import signal
import sys

signal.signal(signal.SIGINT, signal.SIG_DFL)
signal.signal(signal.SIGQUIT, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])
PY

# _run_interrupted <signal> <repo> <report> -- the script under that signal.
# It cannot be fixtures' _run: that one runs the script in a command
# substitution, which has to finish before this suite could signal anything.
# rc still comes from a bare `wait`, with no pipeline in the way.
#
# Two knobs, each read as `NAME=value _run_interrupted ...` so it resets itself,
# the same shape renovate-fixtures.sh uses for _run: SIG_PATH swaps the stub
# directory and SIG_MGRS the managers, which is what lets (X12) put the signal
# in the SUBMODULE half instead of the lock refresh.
_run_interrupted() {
  local sig="$1" repo="$2" report="$3"
  local log="${WORK}/sig-${sig}-${repo##*/}.log"
  rm -f "${SIG_PIDFILE}"
  PATH="${SIG_PATH:-${SIG_STUBS}}:${BARE_PATH}" PREFLIGHT_PYTHON="${PY_ABS}" \
    RENOVATE_LOCAL_REPORT="${report}" RENOVATE_LOCAL_CONFIG="${CONFIG}" \
    TMPDIR="${SIG_TMP}" RL_REAL_GIT="${GIT_ABS}" \
    RL_SIGNAL_PIDFILE="${SIG_PIDFILE}" RL_SIGNAL_SIG="${sig}" \
    "${PY_ABS}" "${SIGSAFE}" bash "${SCRIPT}" \
      --apply --managers "${SIG_MGRS:-cargo}" "${repo}" > "${log}" 2>&1 &
  local pid=$!
  printf '%s\n' "${pid}" > "${SIG_PIDFILE}"
  wait "${pid}"
  RC=$?
  OUT="$(cat "${log}")"
  return 0
}
GIT_ABS="$(command -v git)"

SIG_REPORT="${WORK}/sig.json"
_report "${SIG_REPORT}" cargo Cargo.toml serde =1.0.100 =1.0.229

# _asserts_undone <repo> <what the code must be> -- the three facts every
# interrupted run owes, kept in one place because the two signal cases differ
# only in the number and INT is the one that used to exit 0.
_asserts_undone() {
  t_assert_eq "$2" "${RC}" "a stopped run is never reported as a finished one"
  t_assert_eq 'serde = "=1.0.100"' "$(_cargo_line "$1" 5)" "the manifest is back"
  t_assert_eq "# lock-bytes" "$(cat "$1/Cargo.lock")" "and so is the half-written lock"
  t_assert_ok git -C "$1" diff --quiet HEAD
  t_assert_eq "" "$(ls -A "${SIG_TMP}")" \
    "the copies go only because every file was PROVEN put back"
}

t_case "(X8) SIGINT part way through the lock refresh undoes the run, rc 130"
X8="$(_cargo_repo x8)"
printf '# lock-bytes\n' > "${X8}/Cargo.lock"
_commit "${X8}"
_run_interrupted INT "${X8}" "${SIG_REPORT}"
t_assert_contains "${OUT}" "SIGINT received" "the run says what stopped it"
t_assert_contains "${OUT}" "a signal is not permission to leave one behind" \
  "and why it undid the write rather than keeping it"
_asserts_undone "${X8}" 130

t_case "(X9) and SIGTERM -- what a CI cancel sends -- is 143, not a finished run"
X9="$(_cargo_repo x9)"
printf '# lock-bytes\n' > "${X9}/Cargo.lock"
_commit "${X9}"
_run_interrupted TERM "${X9}" "${SIG_REPORT}"
t_assert_contains "${OUT}" "SIGTERM received" "the run names the signal"
_asserts_undone "${X9}" 143

# The other half of the rule: a copy is deleted because the file was proven put
# back, never because nobody looked. "RESTORE_FAILED is empty" was not that
# test -- it is also empty when no restore was ever attempted.
t_case "(X10) a file that would NOT go back keeps its copy on disk"
KEEP_TMP="${WORK}/keep-tmp"
KEEP_STUBS="${WORK}/keep-stubs"
mkdir -p "${KEEP_TMP}" "${KEEP_STUBS}"
cat > "${KEEP_STUBS}/cargo" <<'STUB'
#!/usr/bin/env bash
printf 'touched\n' >> Cargo.lock
chmod 444 Cargo.toml Cargo.lock
exit 1
STUB
chmod +x "${KEEP_STUBS}/cargo"
X10="$(_cargo_repo x10)"
STUB_PATH="${KEEP_STUBS}:${BARE_PATH}" RUN_TMPDIR="${KEEP_TMP}" \
  _run "${X10}" "${SIG_REPORT}" --apply --managers cargo
chmod 644 "${X10}/Cargo.toml" "${X10}/Cargo.lock"
t_assert_eq "1" "${RC}" "the run must FAIL"
t_assert_contains "${OUT}" "could NOT be put back" "and name what is stuck"
t_assert_contains "${OUT}" "the copies are kept at" "and where the only copy is"
t_assert_eq "1" "$(find "${KEEP_TMP}" -mindepth 1 -maxdepth 1 -type d | wc -l)" \
  "the backup directory is still there"
t_assert_eq 'serde = "=1.0.100"' \
  "$(grep -h '^serde' "${KEEP_TMP}"/*/* 2>/dev/null | head -1)" \
  "and it holds the bytes the manifest had before the run"

# ...and that a human can tell WHICH file each copy is. The copies are named 0
# and 1 -- restore_targets indexes them by position -- so without a mapping on
# DISK the only thing that knew where they belonged was an array in a process
# that is, by the time anyone reads them, gone.
t_assert_contains "$(cat "${KEEP_TMP}"/*/MANIFEST)" "0	Cargo.toml" \
  "the mapping names the file each copy came from"
t_assert_contains "$(cat "${KEEP_TMP}"/*/MANIFEST)" "1	Cargo.lock" \
  "for every copy, not just the first"
t_assert_contains "$(cat "${KEEP_TMP}"/*/MANIFEST)" "cp -p " \
  "and says how to put one back without this script"
# A restore that got STUCK is not a tree anyone should run over again, so the
# marker (X14) stays: this is the one exit where it survives on purpose.
t_assert_ok test -f "${X10}/.git/renovate-local-inflight"

# --------------------------------------------------------------------------
# The gitlink half is undone too
# --------------------------------------------------------------------------
# Until 2026-09-10 it was not, and could not be: the undo walked BACKUP_PATHS,
# which holds manifests and lockfiles only, and apply_files() had already
# SETTLED -- discarding every copy -- one line before the submodule half began.
# So a `git submodule update --remote` that failed exited 1 with the manifests
# written and the copies gone, under a code documented as "the tree is where it
# started". Measured, on this fixture, before the fix.

# The same superproject-plus-manifest fixture, with the submodule's own origin
# pointed at nothing: the fetch inside `submodule update --remote` must fail,
# which is the one failure no pre-flight can predict. The manifest half has by
# then written pubspec.yaml, so this asks the whole question in one run.
_broken_sub_repo() {
  local d
  d="$(_sub_repo "$1")"
  git -C "${d}/sub" remote set-url origin "${WORK}/no-such-remote-$1"
  printf '%s' "${d}"
}

# The three facts a run owes about the TREE when it did not apply: the manifest
# at its old value, the submodule at the commit AND the ref it was on, and
# nothing left for `git status` to report. Five cases below assert exactly this
# triple -- writing it out five times is the copy the duplication gate catches,
# and it is the same reason _asserts_undone above has one owner.
#   _asserts_tree_intact <repo> <_sub_at recorded before the run>
_asserts_tree_intact() {
  t_assert_eq "  http: 1.1.0" "$(_pub "$1" 3)" "the manifest is at its old value"
  t_assert_eq "$2" "$(_sub_at "$1")" "the gitlink is at the same commit AND ref"
  t_assert_ok git -C "$1" diff --quiet HEAD
}

t_case "(X11) the submodule half failing puts the MANIFEST half back as well"
X11="$(_broken_sub_repo x11)"
X11_AT="$(_sub_at "${X11}")"
X11_TMP="${WORK}/x11-tmp"
mkdir -p "${X11_TMP}"
RUN_TMPDIR="${X11_TMP}" _run "${X11}" "${SUB_REPORT}" --apply --managers pub,git-submodules
t_assert_eq "1" "${RC}" "the run could not complete"
t_assert_contains "${OUT}" "git submodule update --remote failed" "and says which half"
# The manifest the FIRST half wrote is what this case is really about.
_asserts_tree_intact "${X11}" "${X11_AT}"
t_assert_eq "" "$(ls -A "${X11_TMP}")" "the copies went because everything was put back"
t_assert_fails test -f "${X11}/.git/renovate-local-inflight"

# rc 1 is only honest if it means the same thing here as everywhere else, and
# the docs say it means "the tree is where it started". That is a claim about
# the TREE, so read the tree.
t_case "(X11b) and a gitlink that DID move is put back attached, not detached"
X11B="$(_sub_repo x11b)"
X11B_AT="$(_sub_at "${X11B}")"
# This one's remote works, so the gitlink really moves; the LOCK half is what
# fails, after both halves have written. `--remote` leaves a submodule detached
# at the new tip, so putting it back means the branch as well as the commit.
printf 'name: fixture\ndependencies:\n  http: 1.1.0\n' > "${X11B}/pubspec.yaml"
printf '# placeholder\n' > "${X11B}/pubspec.lock"
_commit "${X11B}"
X11B_STUBS="${WORK}/x11b-stubs"
mkdir -p "${X11B_STUBS}"
printf '#!/usr/bin/env bash\nexit 1\n' > "${X11B_STUBS}/dart"
chmod +x "${X11B_STUBS}/dart"
STUB_PATH="${X11B_STUBS}:${BARE_PATH}" \
  _run "${X11B}" "${SUB_REPORT}" --apply --managers pub,git-submodules
t_assert_eq "1" "${RC}" "a lock tool that fails still ends the whole run"
_asserts_tree_intact "${X11B}" "${X11B_AT}"

# A git that hands the run its signal at the moment the submodule checkout
# starts, and is real git for everything else. RL_REAL_GIT rather than a baked
# path, so nothing in this stub needs escaping.
SUB_STUBS="${WORK}/sub-stubs"
mkdir -p "${SUB_STUBS}"
cat > "${SUB_STUBS}/git" <<'STUB'
#!/usr/bin/env bash
_sub=""
for a in "$@"; do
  case "${a}" in
    submodule) _sub=1 ;;
    update)
      if [ -n "${_sub}" ]; then
        while [ ! -s "${RL_SIGNAL_PIDFILE}" ]; do sleep 0.05; done
        kill -"${RL_SIGNAL_SIG}" "$(cat "${RL_SIGNAL_PIDFILE}")"
        sleep 0.5
      fi ;;
  esac
done
exec "${RL_REAL_GIT}" "$@"
STUB
chmod +x "${SUB_STUBS}/git"

t_case "(X12) a signal in the SUBMODULE half undoes both halves, not neither"
X12="$(_sub_repo x12)"
X12_AT="$(_sub_at "${X12}")"
SIG_PATH="${SUB_STUBS}" SIG_MGRS=pub,git-submodules \
  _run_interrupted INT "${X12}" "${SUB_REPORT}"
t_assert_eq "130" "${RC}" "a stopped run is never reported as a finished one"
t_assert_contains "${OUT}" "SIGINT received" "the run says what stopped it"
t_assert_contains "${OUT}" "back at the commit it was checked" \
  "and says it put the gitlink back, which it used not to do at all"
_asserts_tree_intact "${X12}" "${X12_AT}"
t_assert_eq "" "$(ls -A "${SIG_TMP}")" "and the copies went because it was PROVEN"

# --------------------------------------------------------------------------
# SIGPIPE -- the signal a human sends by accident
# --------------------------------------------------------------------------
# `renovate-local.sh --apply ... | head -n 9`, or `| less` and then q. It was
# the one signal not trapped, so it was fatal by default: the run died at
# whichever byte it had reached, with no undo and no EXIT trap. Measured at
# three cut points; the deepest left the manifest at its new value with the
# lockfile never refreshed, which is the half-applied tree the design forbids.
PIPE_TMP="${WORK}/pipe-tmp"
PIPE_STUBS="${WORK}/pipe-stubs"
mkdir -p "${PIPE_TMP}" "${PIPE_STUBS}"
# A lock tool slow enough that the reader is gone before it returns, which is
# what a real `cargo update` or `npm install` is.
cat > "${PIPE_STUBS}/cargo" <<'STUB'
#!/usr/bin/env bash
printf 'half\n' >> Cargo.lock
sleep 1
exit 0
STUB
chmod +x "${PIPE_STUBS}/cargo"

# The run with its stdout cut after <cut> lines. `set -o pipefail` inside a
# SUBSHELL is the whole point: without it $? is head's status, which is 0, and
# that is exactly how the owner read a killed run as a passing one twice in one
# day. RC comes from the subshell, with no pipeline between.
_run_piped() {
  local repo="$1" report="$2" cut="$3"
  local log="${WORK}/pipe-${cut}.err"
  ( set -o pipefail
    PATH="${PIPE_STUBS}:${BARE_PATH}" PREFLIGHT_PYTHON="${PY_ABS}" \
      RENOVATE_LOCAL_REPORT="${report}" RENOVATE_LOCAL_CONFIG="${CONFIG}" \
      TMPDIR="${PIPE_TMP}" \
      bash "${SCRIPT}" --apply --managers cargo "${repo}" 2>"${log}" \
      | head -n "${cut}" >/dev/null )
  RC=$?
  OUT="$(cat "${log}")"
  return 0
}

t_case "(X13) SIGPIPE at three cut points leaves the tree exactly as it started"
for _cut in 3 6 9; do
  X13="$(_cargo_repo "x13-${_cut}")"
  printf '# lock-bytes\n' > "${X13}/Cargo.lock"
  _commit "${X13}"
  rm -rf "${PIPE_TMP:?}"/*
  _run_piped "${X13}" "${SIG_REPORT}" "${_cut}"
  # Two mechanisms end the run, and which one wins is a race: the PIPE trap
  # (141) when SIGPIPE lands on a write, or bash's EPIPE-on-builtin path (1)
  # when the builtin's write fails first. Both are failures; the tree
  # assertions below are the part that must not vary.
  if [ "${RC}" = "141" ]; then
    t_assert_eq "141" "${RC}" "a run cut off at line ${_cut} died on SIGPIPE"
  else
    t_assert_eq "1" "${RC}" "a run cut off at line ${_cut} died on the EPIPE path, not head's 0"
  fi
  t_assert_eq 'serde = "=1.0.100"' "$(_cargo_line "${X13}" 5)" \
    "the manifest is untouched at cut ${_cut}"
  t_assert_eq "# lock-bytes" "$(cat "${X13}/Cargo.lock")" \
    "and the lock is untouched at cut ${_cut}"
  t_assert_ok git -C "${X13}" diff --quiet HEAD
  t_assert_eq "" "$(ls -A "${PIPE_TMP}")" "no copies are stranded at cut ${_cut}"
  t_assert_fails test -f "${X13}/.git/renovate-local-inflight"
done
# The undo has to be SAID somewhere the human can still read. stdout is the pipe
# that just closed, so on_signal moves to stderr -- which `| head` leaves open.
t_assert_contains_any "${OUT}" "the run names the dead pipe on stderr, because stdout is gone" \
  "SIGPIPE received" "Broken pipe"

# --------------------------------------------------------------------------
# The one that cannot be undone, and therefore has to be declared
# --------------------------------------------------------------------------
# SIGKILL cannot be trapped. That is not a reason to leave the next run reading
# the wreckage as good news, which is what it did: measured 2026-09-10, a run
# killed mid-refresh left Cargo.toml at its new value beside a Cargo.lock that
# was never refreshed, and the NEXT run over the same report exited 0 calling
# it "already applied".
t_case "(X14) after a SIGKILL the next run REFUSES the wreckage instead of exiting 0"
X14="$(_cargo_repo x14)"
printf '# lock-bytes\n' > "${X14}/Cargo.lock"
_commit "${X14}"
# The SAME stub and the SAME runner as (X8) and (X9). The only thing that makes
# this the untrappable case is the signal NAME, so nothing here needs a launcher
# of its own -- and a second copy of one is the clone the duplication gate
# catches. The stub sends the signal and keeps sleeping; a SIGKILL does not wait
# for the run to reach a trap, because there is no trap to reach.
_run_interrupted KILL "${X14}" "${SIG_REPORT}"
t_assert_eq "137" "${RC}" "the kill lands, and it cannot be trapped"
t_assert_ok test -f "${X14}/.git/renovate-local-inflight"

# The marker has to carry what the dead process knew, because nothing else does.
X14_MARK="$(cat "${X14}/.git/renovate-local-inflight")"
t_assert_contains "${X14_MARK}" "Cargo.toml" "the marker names the files in flight"
t_assert_contains "${X14_MARK}" "Cargo.lock" "every one of them"
t_assert_contains "${X14_MARK}" "copies of the ORIGINAL bytes" "and where the copies are"

_run "${X14}" "${SIG_REPORT}" --apply --managers cargo
t_assert_eq "1" "${RC}" "the next run cannot complete over a half-applied tree"
t_assert_contains "${OUT}" "may be HALF-APPLIED" "and says exactly what is wrong"
t_assert_contains "${OUT}" "rm ${X14}/.git/renovate-local-inflight" \
  "and tells the human the one command that clears it"
# A refusal that nothing can clear is a broken tool, so prove the way out works
# -- and prove it with the two commands the refusal itself printed. The stub
# cargo is on PATH here because the tree is now applyable again, which is the
# whole point: the marker was the only thing standing in the way.
rm -f "${X14}/.git/renovate-local-inflight"
git -C "${X14}" checkout -- Cargo.toml Cargo.lock
_run_stubbed "${X14}" "${SIG_REPORT}" --apply --managers cargo
t_assert_eq "0" "${RC}" "with the marker cleared and the tree put right, it runs"
t_assert_eq 'serde = "=1.0.229"' "$(_cargo_line "${X14}" 5)" "and this time it applies"

# The marker is the ONLY thing a human gets after a kill, so what it says about
# a SUBMODULE has to be enough to act on: which path, and the commit to put it
# back to. Read from INSIDE the run, by a lock tool that runs after the manifest
# edit and before the gitlink half -- which is exactly when the tree is in
# flight and the marker is on disk.
t_case "(X14b) the marker names the submodule and the commit it was at"
X14B="$(_sub_repo x14b)"
printf '# placeholder\n' > "${X14B}/pubspec.lock"
_commit "${X14B}"
X14B_AT="$(git -C "${X14B}/sub" rev-parse HEAD)"
MARK_STUBS="${WORK}/mark-stubs"
mkdir -p "${MARK_STUBS}"
cat > "${MARK_STUBS}/dart" <<'STUB'
#!/usr/bin/env bash
cp "${RL_MARK}" "${RL_MARK_COPY}"
exit 0
STUB
chmod +x "${MARK_STUBS}/dart"
RL_MARK="${X14B}/.git/renovate-local-inflight" RL_MARK_COPY="${WORK}/x14b-mark" \
  STUB_PATH="${MARK_STUBS}:${BARE_PATH}" \
  _run "${X14B}" "${SUB_REPORT}" --apply --managers pub,git-submodules
t_assert_eq "0" "${RC}" "the run itself succeeds; the marker is read in passing"
X14B_MARK="$(cat "${WORK}/x14b-mark")"
t_assert_contains "${X14B_MARK}" "pubspec.yaml" "the marker names the manifest in flight"
t_assert_contains "${X14B_MARK}" "sub	${X14B_AT}" \
  "and the submodule with the commit to put it back to"
t_assert_contains "${X14B_MARK}" "refs/heads/main" "and the branch it was attached to"
# ...and a run that finished BOTH halves leaves no marker behind, or every run
# after it would refuse.
t_assert_fails test -f "${X14B}/.git/renovate-local-inflight"

# --------------------------------------------------------------------------
# What --dry-run can and cannot promise
# --------------------------------------------------------------------------
# "--dry-run exits what --apply will exit" is true of every verdict a PLAN can
# reach, and measurably false of one class: a tool the pre-flight proved present
# that then fails at runtime. Nothing can predict that without running it, and
# running it is the write --dry-run exists not to do. So the promise --dry-run
# actually makes is about the TREE, and this is where it is pinned.
t_case "(X15) --dry-run cannot predict a tool that fails, and neither run writes"
# Each repo is compared against ITS OWN recorded position, never against the
# other's: two _sub_repo fixtures have two separate upstreams, so their commit
# shas agree only when both happened to be committed in the same second. The
# first cut of this case compared across them and passed for exactly that
# reason -- a fixture-shaped flake, not a property of the script.
X15D="$(_broken_sub_repo x15d)"
X15D_AT="$(_sub_at "${X15D}")"
_run "${X15D}" "${SUB_REPORT}" --apply --dry-run --managers pub,git-submodules
t_assert_eq "0" "${RC}" "the plan is clean, because at plan time it IS clean"
X15A="$(_broken_sub_repo x15a)"
X15A_AT="$(_sub_at "${X15A}")"
_run "${X15A}" "${SUB_REPORT}" --apply --managers pub,git-submodules
t_assert_eq "1" "${RC}" "the real run meets the failure the plan could not see"
# The codes differ. The TREE does not, and that is the promise worth having:
# whichever of the two a caller ran, the checkout is untouched.
_asserts_tree_intact "${X15D}" "${X15D_AT}"
_asserts_tree_intact "${X15A}" "${X15A_AT}"

t_summary
