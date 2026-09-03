#!/usr/bin/env bash
# Tests for docs/scripts/verify_mutations.py. It neuters a guarantee to check a
# test can fail, so the two cases that matter most are that the tree it was
# pointed at comes back byte-identical (a build may be reading it) and that
# --in-place, the opt-out these fixtures use, still edits in place and restores.
# docs/code-quality-tooling.md#the-mutation-gate-mutations
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
REPO="$(cd "${TESTS_DIR}/../../.." && pwd)"
PY="${PREFLIGHT_PYTHON:-python3}"
GATE="${REPO}/docs/scripts/verify_mutations.py"

_work="$(mktemp -d)"; _tmp="$(mktemp -d)"
trap 'rm -rf "${_work}" "${_tmp}"' EXIT

# A subject with one guard, a test that may or may not look at it, and a manifest
# naming one mutation. Written with printf: a nested heredoc here was the first
# thing to go wrong. $4 is where the test command reaches for the subject --
# "${_work}" is an absolute path outside any copy (so only --in-place can bite),
# "." is relative to the gate's cwd (so an isolated copy bites instead).
_fixture() {
  local find="$1" replace="$2" test_checks="$3" dir="${4:-${_work}}"
  printf 'GUARD=on\n' > "${_work}/subject.sh"
  if [ "${test_checks}" = "yes" ]; then
    printf 'grep -q "GUARD=on" "%s/subject.sh"\n' "${dir}" > "${_work}/t.sh"
  elif [ "${test_checks}" = "witness" ]; then
    printf 'cp "%s/subject.sh" "%s/witness"\ngrep -q "GUARD=on" "./subject.sh"\n' \
      "${_work}" "${_tmp}" > "${_work}/t.sh"
  elif [ "${test_checks}" = "broken" ]; then
    printf 'exit 1\n' > "${_work}/t.sh"    # a test that is already red
  else
    printf 'true\n' > "${_work}/t.sh"      # a test that cannot fail
  fi
  printf '[{"id":"probe","target":"subject.sh","find":"%s","replace":"%s","test":"bash %s/t.sh","why":"probe"}]\n' \
    "${find}" "${replace}" "${dir}" > "${_work}/m.json"
}

_gate() { TMPDIR="${_tmp}" "${PY}" "${GATE}" --manifest "${_work}/m.json" --root "${_work}" --in-place "$@"; }
_run() { t_out _gate; }
_rc()  { t_rc _gate; }

# Same gate without the opt-out: every mutation lands in a throwaway copy.
_iso() { TMPDIR="${_tmp}" "${PY}" "${GATE}" --manifest "${_work}/m.json" --root "${_work}" "$@"; }
_iso_run() { t_out _iso; }
_iso_rc()  { t_rc _iso; }
_snapshot() { (cd "${_work}" && find . -type f -exec md5sum {} + | LC_ALL=C sort); }

t_case "a mutation the tests catch is reported as biting"
_fixture "GUARD=on" "GUARD=off" yes
t_assert_contains "$(_run)" "bites" "the guarded test must go red"
t_assert_eq "0" "$(_rc)" "a caught mutation is the healthy case"

t_case "a mutation the tests SURVIVE is the whole point, and fails the gate"
_fixture "GUARD=on" "GUARD=off" no
_out="$(_run)"
t_assert_contains "${_out}" "SURVIVED" "a test that passes without the guard must be named"
# The message is not the contract: it has to EXIT non-zero, or CI stays green on
# a vacuous test. Naming the problem and passing anyway is the failure mode this
# whole tool exists to find.
t_assert_eq "1" "$(_rc)" "a surviving mutation must fail the gate, not just print"
t_assert_contains "${_out}" "guarantee removed" "the message must say what it means"

t_case "a stale find string fails instead of silently doing nothing"
_fixture "GUARD=nowhere" "x" yes
t_assert_contains "$(_run)" "stale" "a mutation that no longer applies is dead"
t_assert_eq "1" "$(_rc)" "a stale mutation must fail too -- it is silently testing nothing"

t_case "a test that already fails unmutated is a VACUOUS bite, not a bite"
_fixture "GUARD=on" "GUARD=off" broken
_out="$(_run 2>&1)"
t_assert_contains "${_out}" "baseline test already fails unmutated" \
  "a red suite makes every mutation under it 'fail' for free"
t_assert_eq "1" "$(_rc)" "a vacuous bite must fail the gate, not be recorded as a bite"
case "${_out}" in
  *bites*) t_assert_eq "no bites line" "a bites line" "a vacuous entry must not be reported as biting" ;;
  *)       t_assert_ok true ;;
esac

t_case "--in-place restores the target afterwards, whatever the verdict"
_fixture "GUARD=on" "GUARD=off" yes
_run >/dev/null 2>&1
t_assert_eq "GUARD=on" "$(cat "${_work}/subject.sh")" \
  "a tool that edits in place must never leave the tree mutated"

# --- isolation: the default must not write into the tree it was given ---------
# 2026-09-03: preflight and the pre-commit hook run this gate with the repo as
# root while buildkit reads that same directory as a build context.

t_case "by default the mutation lands in a COPY, and still bites there"
_fixture "GUARD=on" "GUARD=off" yes .
_before="$(_snapshot)"
_out="$(_iso_run)"
t_assert_contains "${_out}" "bites" "isolation must not neuter the gate: the copy is what gets mutated"
t_assert_eq "0" "$(_iso_rc)" "a caught mutation is still the healthy case in a copy"
t_assert_eq "${_before}" "$(_snapshot)" \
  "the tree the gate was pointed at must be byte-identical -- a build may be reading it"

t_case "the pointed-at file is not even TRANSIENTLY mutated while the test runs"
# Restoring afterwards is not enough: a concurrent reader (buildkit snapshotting
# the context) sees whatever is on disk DURING the test. The witness records it.
_fixture "GUARD=on" "GUARD=off" witness .
_before="$(_snapshot)"
t_assert_contains "$(_iso_run)" "bites" "the copy must still be the thing that got mutated"
t_assert_eq "GUARD=on" "$(cat "${_tmp}/witness")" \
  "while the test ran, the tree the gate was pointed at still held the guard"
t_assert_eq "${_before}" "$(_snapshot)" "and it is byte-identical afterwards"

t_case "a FAILING test leaves the pointed-at tree byte-identical too"
_fixture "GUARD=on" "GUARD=off" no .
_before="$(_snapshot)"
t_assert_eq "1" "$(_iso_rc)" "the survivor verdict is unchanged by isolation"
t_assert_eq "${_before}" "$(_snapshot)" "no write escapes the copy on the failing path either"

t_case "the baseline-vacuity check still works, and mutates nothing"
_fixture "GUARD=on" "GUARD=off" broken .
_before="$(_snapshot)"
_out="$(t_out _iso 2>&1)"
t_assert_contains "${_out}" "baseline test already fails unmutated" \
  "an already-red test is still a vacuous bite when the run is isolated"
t_assert_eq "1" "$(_iso_rc)" "a vacuous bite must still fail the gate"
t_assert_eq "${_before}" "$(_snapshot)" "the vacuous path must not write to the tree either"

t_case "the throwaway copy is cleaned up, not leaked into TMPDIR"
_fixture "GUARD=on" "GUARD=off" yes .
_iso_run >/dev/null 2>&1
t_assert_eq "" "$(find "${_tmp}" -maxdepth 1 -name 'mutation-gate-*' -print)" \
  "one leaked copy per invocation fills the disk of the machine running CI"

t_case "--changed selects by target, using the diff of the real repo"
_fixture "GUARD=on" "GUARD=off" yes .
mkdir -p "${_work}/bin"
printf '#!/usr/bin/env bash\nprintf "subject.sh\\n"\n' > "${_work}/bin/git"
chmod +x "${_work}/bin/git"
t_assert_contains "$(PATH="${_work}/bin:${PATH}" t_out _iso --changed)" "bites" \
  "a target named in the diff must be selected"
printf '#!/usr/bin/env bash\nprintf "somewhere/else.sh\\n"\n' > "${_work}/bin/git"
t_assert_contains "$(PATH="${_work}/bin:${PATH}" t_out _iso --changed)" "nothing selected" \
  "a target outside the diff must be skipped, not run"

t_summary
