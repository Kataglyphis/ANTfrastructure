#!/usr/bin/env bash
# Exit codes and what a signal leaves behind; see docs/dependency-updates.md#the-mechanics-of-a-refusal
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/renovate-fixtures.sh"

# Exit codes 0, 1 and 2, and what separates the two non-zero ones.
t_case "(X1) a repo with nothing behind exits 0"
X1="$(_plant x1 pubspec.yaml 'name: fixture\ndependencies:\n  http: 1.1.0\n')"
EMPTY_REPORT="${WORK}/empty.json"
printf '{"repositories":{"local":{"packageFiles":{}}}}\n' > "${EMPTY_REPORT}"
_run "${X1}" "${EMPTY_REPORT}" --apply --managers pub
t_assert_eq "0" "${RC}" "nothing behind, nothing refused, nothing to explain"
t_assert_contains "${OUT}" "up to date" "and it says so"

# The applied and already-applied zeroes are case (a) of test-renovate-local.sh.

# One refused update must not share (X1)'s exit code.
t_case "(X3) a plan-time refusal exits 2, and says how many it did not write"
X3="$(_plant x3 pubspec.yaml 'name: fixture\ndependencies: &deps\n  http: 1.1.0\ndependency_overrides:\n  http: 1.1.0\n')"
_run "${X3}" "${A_REPORT}" --apply --managers pub
t_assert_eq "2" "${RC}" "a refusal is not a pass, and 0 said it was"
t_assert_contains "${OUT}" "NOT EVERYTHING WAS APPLIED: 1 reported update(s)" \
  "the last line counts them, so the code and the text agree"
t_assert_eq "  http: 1.1.0" "$(_pub "${X3}" 3)" "and nothing was written"

# The approval-gated refusal class is asserted in test-renovate-local.sh, where its fixture lives.

# 1: the tree is where it started and a human fixes the cause; 2: it is consistent and a human applies the rest.
t_case "(X5) a run that cannot complete exits 1, never 2"
X5="$(_plant x5 pubspec.yaml 'name: fixture\ndependencies:\n  http: 1.1.0\n')"
printf 'name: fixture\ndependencies:\n  http: 1.1.0\n# edited by hand\n' > "${X5}/pubspec.yaml"
_run "${X5}" "${A_REPORT}" --apply --managers pub
t_assert_eq "1" "${RC}" "the whole run aborted; nothing was even attempted"
t_assert_contains "${OUT}" "these paths have local changes" "and it says why"

# One plan, two files, one refused: the other applies, and partial success is still not success.
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

# All four refusal classes share one counter; an undeclared submodule is the one with no file at all.
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

# Signals: every backup is an `mktemp -d`, so an empty TMPDIR of our own shows whether they were deleted.
SIG_TMP="${WORK}/sig-tmp"
SIG_PIDFILE="${WORK}/sig-pid"
SIG_STUBS="${WORK}/sig-stubs"
mkdir -p "${SIG_TMP}" "${SIG_STUBS}"

# A lock tool that half-writes the lock and then signals the run itself, which keeps the case deterministic.
cat > "${SIG_STUBS}/cargo" <<'STUB'
#!/usr/bin/env bash
printf 'half\n' >> Cargo.lock
while [ ! -s "${RL_SIGNAL_PIDFILE}" ]; do sleep 0.05; done
kill -"${RL_SIGNAL_SIG}" "$(cat "${RL_SIGNAL_PIDFILE}")"
sleep 0.5
STUB
chmod +x "${SIG_STUBS}/cargo"

# Resets SIGINT/SIGQUIT: a command started with `&` inherits them ignored, and bash cannot trap an ignored signal.
SIGSAFE="${WORK}/sigsafe.py"
cat > "${SIGSAFE}" <<'PY'
import os
import signal
import sys

signal.signal(signal.SIGINT, signal.SIG_DFL)
signal.signal(signal.SIGQUIT, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])
PY

# _run_interrupted <signal> <repo> <report>: backgrounded, not _run's substitution; SIG_PATH and SIG_MGRS override stubs and managers.
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

# _asserts_undone <repo> <rc>: what every interrupted run owes.
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

# A copy is deleted only once its file is proven put back, not because no restore was attempted.
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

# Copies are named by position, so the MANIFEST on disk is the only record of where each belongs.
t_assert_contains "$(cat "${KEEP_TMP}"/*/MANIFEST)" "0	Cargo.toml" \
  "the mapping names the file each copy came from"
t_assert_contains "$(cat "${KEEP_TMP}"/*/MANIFEST)" "1	Cargo.lock" \
  "for every copy, not just the first"
t_assert_contains "$(cat "${KEEP_TMP}"/*/MANIFEST)" "cp -p " \
  "and says how to put one back without this script"
# A stuck restore keeps the (X14) marker: the one exit where it survives on purpose.
t_assert_ok test -f "${X10}/.git/renovate-local-inflight"

# The gitlink half: a failed `submodule update --remote` must undo the already-written manifest half too.

# _broken_sub_repo <name>: the submodule's origin points at nothing, so its fetch fails after the manifest is written.
_broken_sub_repo() {
  local d
  d="$(_sub_repo "$1")"
  git -C "${d}/sub" remote set-url origin "${WORK}/no-such-remote-$1"
  printf '%s' "${d}"
}

# _asserts_tree_intact <repo> <_sub_at before the run>: old manifest, same gitlink commit and ref, clean status.
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

# rc 1 claims the tree is where it started, so the tree is read.
t_case "(X11b) and a gitlink that DID move is put back attached, not detached"
X11B="$(_sub_repo x11b)"
X11B_AT="$(_sub_at "${X11B}")"
# The gitlink moves and the lock half fails; `--remote` detaches, so the branch is restored as well.
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

# A git that signals the run as the submodule checkout starts, and is real git otherwise.
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

# SIGPIPE, sent by `| head` or quitting `less`, must be trapped and undone like any other signal.
PIPE_TMP="${WORK}/pipe-tmp"
PIPE_STUBS="${WORK}/pipe-stubs"
mkdir -p "${PIPE_TMP}" "${PIPE_STUBS}"
# Slow enough that the reader is gone before it returns, like a real `cargo update`.
cat > "${PIPE_STUBS}/cargo" <<'STUB'
#!/usr/bin/env bash
printf 'half\n' >> Cargo.lock
sleep 1
exit 0
STUB
chmod +x "${PIPE_STUBS}/cargo"

# _run_piped <repo> <report> <cut>: pipefail in the subshell, or $? is head's 0.
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
  # The PIPE trap (141) and bash's EPIPE path (1) race; only the tree assertions must not vary.
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
# stdout is the closed pipe, so on_signal reports on stderr, which `| head` leaves open.
t_assert_contains_any "${OUT}" "the run names the dead pipe on stderr, because stdout is gone" \
  "SIGPIPE received" "Broken pipe"

# SIGKILL cannot be trapped, so the next run must refuse the half-applied tree, not call it applied.
t_case "(X14) after a SIGKILL the next run REFUSES the wreckage instead of exiting 0"
X14="$(_cargo_repo x14)"
printf '# lock-bytes\n' > "${X14}/Cargo.lock"
_commit "${X14}"
# The stub and runner of (X8) and (X9): only the signal name makes this the untrappable case.
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
# A refusal nothing can clear is a broken tool, so the two commands it printed must work.
rm -f "${X14}/.git/renovate-local-inflight"
git -C "${X14}" checkout -- Cargo.toml Cargo.lock
_run_stubbed "${X14}" "${SIG_REPORT}" --apply --managers cargo
t_assert_eq "0" "${RC}" "with the marker cleared and the tree put right, it runs"
t_assert_eq 'serde = "=1.0.229"' "$(_cargo_line "${X14}" 5)" "and this time it applies"

# After a kill the marker is all a human gets; a lock stub reads it mid-run, while the tree is in flight.
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
# A run that finished both halves leaves no marker, or every later run would refuse.
t_assert_fails test -f "${X14B}/.git/renovate-local-inflight"

# --dry-run cannot predict a tool that fails at runtime, so its promise is about the tree, not the exit code.
t_case "(X15) --dry-run cannot predict a tool that fails, and neither run writes"
# Each repo is compared with its own recorded position: two fixtures' shas agree only by timing.
X15D="$(_broken_sub_repo x15d)"
X15D_AT="$(_sub_at "${X15D}")"
_run "${X15D}" "${SUB_REPORT}" --apply --dry-run --managers pub,git-submodules
t_assert_eq "0" "${RC}" "the plan is clean, because at plan time it IS clean"
X15A="$(_broken_sub_repo x15a)"
X15A_AT="$(_sub_at "${X15A}")"
_run "${X15A}" "${SUB_REPORT}" --apply --managers pub,git-submodules
t_assert_eq "1" "${RC}" "the real run meets the failure the plan could not see"
# The codes differ, but either way the checkout is untouched.
_asserts_tree_intact "${X15D}" "${X15D_AT}"
_asserts_tree_intact "${X15A}" "${X15A_AT}"

t_summary
