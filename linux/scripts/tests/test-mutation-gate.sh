#!/usr/bin/env bash
# The pointed-at tree must stay byte-identical, since a build may be reading it; see docs/code-quality-tooling.md#the-mutation-gate-mutations
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
REPO="$(cd "${TESTS_DIR}/../../.." && pwd)"
PY="${PREFLIGHT_PYTHON:-python3}"
GATE="${REPO}/docs/scripts/verify_mutations.py"

_work="$(mktemp -d)"; _tmp="$(mktemp -d)"
trap 'rm -rf "${_work}" "${_tmp}"' EXIT

# _fixture <find> <replace> <yes|witness|broken|no> [dir]: "${_work}" is outside any copy, "." inside it.
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

# _posix_host <what>: false on MSYS, whose Python lacks process groups, mode bits and PATH scripts; Linux CI proves those.
_posix_host() {
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*)
      printf '  SKIP [%s] needs a POSIX host for %s\n' "${_T_CASE}" "$1" >&2
      return 1 ;;
  esac
  return 0
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
# The exit code is the contract: a printed SURVIVED that exits 0 keeps CI green.
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

# The same gate believing it runs under Git Bash, so the host-skip arms are proven on Linux too.
_gate_as_gitbash() {
  TMPDIR="${_tmp}" "${PY}" -c 'import runpy, sys; sys.platform = "msys"; sys.argv = sys.argv[1:]; runpy.run_path(sys.argv[0], run_name="__main__")' \
    "${GATE}" --manifest "${_work}/m.json" --root "${_work}" --in-place
}

t_case "on Git Bash a suite that exits 77 is a listed skip, and the run stays green"
_fixture "GUARD=on" "GUARD=off" no
printf 'echo "  SKIP [t.sh] this host lacks the frobnicator"; exit 77\n' > "${_work}/t.sh"
_out="$(t_out _gate_as_gitbash)"
t_assert_contains "${_out}" "skip    probe"
t_assert_contains "${_out}" "this host lacks the frobnicator" "the skip must say what the host lacks"
t_assert_contains "${_out}" "1 skipped here" "the verdict must not claim every mutation was proven"
t_assert_eq "0" "$(t_rc _gate_as_gitbash)"

t_case "on Linux the same exit 77 is a vacuous bite and fails the gate"
t_needs "a POSIX python3 (the gate reads a Windows one as a Git Bash host)" t_posix_python
t_assert_contains "$(_run 2>&1)" "baseline test already fails unmutated"
t_assert_eq "1" "$(_rc)"

t_case "on Git Bash a mutation only a waived case catches is a skip, never SURVIVED"
_fixture "GUARD=on" "GUARD=off" no
printf 'grep -q "GUARD=on" "%s/subject.sh" || echo "  1 failed assertion(s) waived: x"\necho "  1 assertion(s) passed"\n' \
  "${_work}" > "${_work}/t.sh"
_out="$(t_out _gate_as_gitbash)"
t_assert_contains "${_out}" "survived where this host skips 1 case(s) of its suite"
t_assert_eq "0" "$(t_rc _gate_as_gitbash)"

t_case "on Git Bash a survivor in a suite that SKIPs a case here is a skip too"
# The _posix_host shape: the case never runs, so mutated and baseline runs look alike.
_fixture "GUARD=on" "GUARD=off" no
printf 'echo "  SKIP [probe case] needs a POSIX host for process groups"\necho "  1 assertion(s) passed"\n' > "${_work}/t.sh"
t_assert_contains "$(t_out _gate_as_gitbash)" "survived where this host skips 1 case(s) of its suite"
t_assert_eq "0" "$(t_rc _gate_as_gitbash)"

t_case "on Linux a SKIP line or a waiver changes nothing: the same mutation SURVIVED"
t_needs "a POSIX python3 (the gate reads a Windows one as a Git Bash host)" t_posix_python
t_assert_contains "$(_run 2>&1)" "SURVIVED"
t_assert_eq "1" "$(_rc)"

t_case "--in-place restores the target afterwards, whatever the verdict"
_fixture "GUARD=on" "GUARD=off" yes
_run >/dev/null 2>&1
t_assert_eq "GUARD=on" "$(cat "${_work}/subject.sh")" \
  "a tool that edits in place must never leave the tree mutated"

t_case "the restore is byte-exact: an LF and a CRLF target keep their line endings"
# Text mode restored LF files as CRLF on Windows, so a later baseline's exact-newline match failed (CON134).
for _eol in '\n' '\r\n'; do
  _fixture "GUARD=on" "GUARD=off" yes
  printf 'GUARD=on%bkeep%b' "${_eol}" "${_eol}" > "${_work}/subject.sh"
  _before="$(md5sum < "${_work}/subject.sh")"
  t_assert_contains "$(_run)" "bites"
  t_assert_eq "${_before}" "$(md5sum < "${_work}/subject.sh")" \
    "the restored target must be the bytes it held, line endings included (${_eol})"
done

t_case "a multi-line find applies to a CRLF target, and the mutant keeps its CRLF"
# core.autocrlf checks some targets out as CRLF; the manifest's finds are LF.
_fixture 'GUARD=on\nkeep' 'GUARD=off\nkeep' yes
printf 'GUARD=on\r\nkeep\r\n' > "${_work}/subject.sh"
printf 'cp ./subject.sh "%s/mutant"\ngrep -q "GUARD=on" ./subject.sh\n' "${_tmp}" > "${_work}/t.sh"
t_assert_contains "$(_run)" "bites" "an LF find must still name its edit in a CRLF checkout"
t_assert_eq "$(printf 'GUARD=off\r\nkeep\r\n' | md5sum)" "$(md5sum < "${_tmp}/mutant")" \
  "the mutant must differ from its target by the edit alone, not by its line endings"
rm -f "${_tmp}/mutant"

# Isolation: preflight and the hook point the gate at the tree buildkit may be reading.

t_case "by default the mutation lands in a COPY, and still bites there"
_fixture "GUARD=on" "GUARD=off" yes .
_before="$(_snapshot)"
_out="$(_iso_run)"
t_assert_contains "${_out}" "bites" "isolation must not neuter the gate: the copy is what gets mutated"
t_assert_eq "0" "$(_iso_rc)" "a caught mutation is still the healthy case in a copy"
t_assert_eq "${_before}" "$(_snapshot)" \
  "the tree the gate was pointed at must be byte-identical -- a build may be reading it"

t_case "the pointed-at file is not even TRANSIENTLY mutated while the test runs"
# A concurrent reader sees the disk during the test, so restoring afterwards is not enough.
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
if _posix_host "a script named git on PATH"; then
_fixture "GUARD=on" "GUARD=off" yes .
mkdir -p "${_work}/bin"
printf '#!/usr/bin/env bash\nprintf "subject.sh\\n"\n' > "${_work}/bin/git"
chmod +x "${_work}/bin/git"
t_assert_contains "$(PATH="${_work}/bin:${PATH}" t_out _iso --changed)" "bites" \
  "a target named in the diff must be selected"
printf '#!/usr/bin/env bash\nprintf "somewhere/else.sh\\n"\n' > "${_work}/bin/git"
t_assert_contains "$(PATH="${_work}/bin:${PATH}" t_out _iso --changed)" "nothing selected" \
  "a target outside the diff must be skipped, not run"
# --base moves where the committed range starts; the pre-push hook passes the remote's tip.
printf '#!/usr/bin/env bash\ncase "$*" in *"tip123...HEAD"*) printf "subject.sh\\n" ;; esac\n' > "${_work}/bin/git"
t_assert_contains "$(PATH="${_work}/bin:${PATH}" t_out _iso --changed --base tip123)" "bites" \
  "the commits since the named base must be the ones selected"
t_assert_contains "$(PATH="${_work}/bin:${PATH}" t_out _iso --changed)" "nothing selected" \
  "without --base the diff is still origin/main's"
fi

t_case "--changed also selects by the TEST an entry runs, not only by target"
# A commit that only weakens a test touches no target; matching the test path re-verifies it.
if _posix_host "a script named git on PATH"; then
_fixture "GUARD=on" "GUARD=off" yes .
printf '#!/usr/bin/env bash\nprintf "t.sh\\n"\n' > "${_work}/bin/git"
t_assert_contains "$(PATH="${_work}/bin:${PATH}" t_out _iso --changed)" "bites" \
  "an entry whose test file is in the diff must be selected"
fi

# --stale-check runs no test, which makes it cheap enough for a hook and no substitute for the gate.

_stale() { TMPDIR="${_tmp}" "${PY}" "${GATE}" --manifest "${_work}/m.json" --root "${_work}" --stale-check; }
_ran() { if [ -e "${_tmp}/ran" ]; then echo ran; else echo not-run; fi; }
# A test command whose only job is to record that it was executed at all.
_marker_test() { rm -f "${_tmp}/ran"; printf 'touch "%s/ran"\n' "${_tmp}" > "${_work}/t.sh"; }

t_case "--stale-check fails an entry whose find string no longer matches"
_fixture "GUARD=nowhere" "x" yes
_marker_test
t_assert_contains "$(t_out _stale)" "stale" "the reader has to be told which entry rotted"
t_assert_eq "1" "$(t_rc _stale)" "a mutation that cannot be applied is silently testing nothing"
t_assert_eq "not-run" "$(_ran)" \
  "running the suites would cost minutes; the whole point is one read per target"

t_case "--stale-check passes a manifest that still applies, and runs no test there either"
_fixture "GUARD=on" "GUARD=off" yes
_marker_test
t_assert_contains "$(t_out _stale)" "still applies"
t_assert_eq "0" "$(t_rc _stale)"
t_assert_eq "not-run" "$(_ran)"

t_case "--stale-check is NOT the gate: a mutation the tests SURVIVE still passes it"
# It answers 'does this edit still apply', never 'can the test fail'.
_fixture "GUARD=on" "GUARD=off" no
t_assert_eq "0" "$(t_rc _stale)" "a survivor is invisible to a check that runs no test"
t_assert_eq "1" "$(_rc)" "and the real gate still fails on the same manifest"

t_case "--stale-check catches the other ways an entry stops applying"
_fixture "GUARD=on" "GUARD=off" yes
printf 'GUARD=on\n' >> "${_work}/subject.sh"
t_assert_contains "$(t_out _stale)" "ambiguous" "two matches would neuter only the first"
t_assert_eq "1" "$(t_rc _stale)"
rm -f "${_work}/subject.sh"
t_assert_contains "$(t_out _stale)" "target missing" "a renamed or moved target is the commonest rot"
t_assert_eq "1" "$(t_rc _stale)"

t_case "--stale-check does not write to the tree it was pointed at"
_fixture "GUARD=on" "GUARD=off" yes
_before="$(_snapshot)"
_stale >/dev/null 2>&1
t_assert_eq "${_before}" "$(_snapshot)" "it reads targets; it must never apply one"

# --- the production call sites: isolation is a DEFAULT, --in-place is one flag away
_gate_calls() { grep -e 'verify_mutations\.py' "$1" || true; }
_count() { printf '%s\n' "$1" | grep -c "${@:2}" || true; }

t_case "the production call sites invoke the gate, and never with --in-place"
_pf_calls="$(_gate_calls "${REPO}/linux/scripts/preflight.sh")"
_hook_calls="$(_gate_calls "${REPO}/linux/host-config/git-hooks/pre-commit")"
t_assert_contains "${_pf_calls}" "run_check mutations" \
  "preflight must run the mutation gate as the 'mutations' slug"
t_assert_eq "1" "$(_count "${_hook_calls}" -E -e 'verify_mutations\.py "\$\{_only\[@\]\}" \|\|')" \
  "the pre-commit hook must gate the commit on the staged-file selection of this gate"
t_assert_eq "0" "$(_count "${_pf_calls}" -e '--in-place')" \
  "preflight must not opt out of isolation: it points the gate at the tree buildkit reads as a build context"
t_assert_eq "0" "$(_count "${_hook_calls}" -e '--in-place')" \
  "the hook must not opt out of isolation: it runs against the live working tree"
_push_calls="$(_gate_calls "${REPO}/linux/host-config/git-hooks/pre-push")"
t_assert_eq "1" "$(_count "${_push_calls}" -e '--stale-check')" \
  "the push hook must run the whole-manifest staleness pass -- nothing else does, between a sampled commit and CI"
t_assert_eq "1" "$(_count "${_push_calls}" -e '--changed')" \
  "and the real gate over what the push adds"
t_assert_eq "0" "$(_count "${_push_calls}" -e '--in-place')" \
  "the push hook must not opt out of isolation either"

t_case "CI proves every entry once: preflight skips the slug, the mutations jobs' shards cover it"
_wf="${REPO}/.github/workflows/linux-x64.yml"
t_assert_contains "$(cat "${REPO}/linux/scripts/preflight.sh")" '${PREFLIGHT_MUTATION_SHARD:+--shard "${PREFLIGHT_MUTATION_SHARD}"}' \
  "the slug must hand its shard to the gate, or every CI job proves the whole manifest"
t_assert_contains "$(cat "${_wf}")" "PREFLIGHT_SKIP=mutations bash linux/scripts/preflight.sh"
_n="$(sed -n 's|.*PREFLIGHT_ONLY=mutations PREFLIGHT_MUTATION_SHARD="${{ matrix.shard }}/\([0-9]*\)" bash linux/scripts/preflight.sh.*|\1|p' "${_wf}")"
t_assert_eq "$(seq -s ', ' 0 $(( ${_n:-0} - 1 )))" "$(sed -n 's/^ *shard: \[\(.*\)\]$/\1/p' "${_wf}")" \
  "the matrix must list K = 0..N-1 for the N its jobs pass, or a slice is never proven"
t_assert_eq "2 2" "$(grep -c -e 'pip install --quiet pytest' "${_wf}") $(grep -c -e 'pip install --quiet pyyaml' "${_wf}")" \
  "both jobs that run preflight.sh need the same setup, or the baselines go vacuous"

t_case "a find string that matches TWICE is an error, not a silent partial edit"
_fixture "GUARD=on" "GUARD=off" yes .
printf 'GUARD=on\n' >> "${_work}/subject.sh"
_out="$(_iso_run)"
t_assert_contains "${_out}" "ambiguous" \
  "a mutation must name ONE edit: replacing the first of several leaves the guarantee half-standing"
t_assert_eq "1" "$(_iso_rc)" "an ambiguous mutation must fail the gate"
case "${_out}" in
  *SURVIVED*) t_assert_eq "an ambiguous-find error" "a SURVIVED verdict" \
    "half-applying the edit turns a real guarantee into a false survivor report" ;;
  *) t_assert_ok true ;;
esac

t_case "the copy keeps file modes, so a mutated script is still executable"
if _posix_host "mode bits"; then
_fixture "GUARD=on" "GUARD=off" yes .
chmod +x "${_work}/subject.sh"
printf 'test -x ./subject.sh || exit 1\ngrep -q "GUARD=on" ./subject.sh\n' > "${_work}/t.sh"
t_assert_contains "$(_iso_run)" "bites" \
  "a mode-losing copy makes every shell test fail for the wrong reason, not for the mutation"
t_assert_eq "0" "$(_iso_rc)" "the executable subject must still produce an honest bite"
fi

t_case "the copy skips the heavy trees, it does not clone the whole checkout"
_fixture "GUARD=on" "GUARD=off" yes .
_heavy=".git/objects out logs archive external linux/webserver/dist"
for _d in ${_heavy}; do mkdir -p "${_work}/${_d}"; printf 'heavy\n' > "${_work}/${_d}/payload"; done
printf 'find . -type f | LC_ALL=C sort > "%s/copied"\ngrep -q "GUARD=on" ./subject.sh\n' \
  "${_tmp}" > "${_work}/t.sh"
t_assert_contains "$(_iso_run)" "bites" "the listing must come from a real, biting run"
_copied="$(cat "${_tmp}/copied")"
t_assert_contains "${_copied}" "./subject.sh" "the tree under test is what gets copied"
for _d in ${_heavy}; do
  case "${_copied}" in
    *"./${_d}/payload"*) t_assert_eq "no ${_d} in the copy" "${_d} was copied" \
      "COPY_EXCLUDES must keep ${_d} out: the gate runs from a pre-commit hook, once per invocation" ;;
    *) t_assert_ok true ;;
  esac
done

# The copy skips git-ignored paths and excluded files, and a failed copy must never read as a vacuous bite.

t_case "a gitignored file in the source is not copied (git is asked at the SOURCE)"
_fixture "GUARD=on" "GUARD=off" yes .
( cd "${_work}" && git init -q . && printf 'blob.bin\nbuild/\n' > .gitignore ) 2>/dev/null
printf 'ignored\n' > "${_work}/blob.bin"; mkdir -p "${_work}/build"; printf 'ignored\n' > "${_work}/build/out"
printf 'tracked\n' > "${_work}/keep.txt"
printf 'find . -type f | LC_ALL=C sort > "%s/copied"\ngrep -q "GUARD=on" ./subject.sh\n' "${_tmp}" > "${_work}/t.sh"
t_assert_contains "$(_iso_run)" "bites" "the listing must come from a real, biting run"
_copied="$(cat "${_tmp}/copied")"
t_assert_contains "${_copied}" "./keep.txt" "an ordinary file is still copied"
case "${_copied}" in *"./blob.bin"*|*"./build/out"*) t_assert_eq "ignored paths absent" "ignored paths copied" \
  "git-ignored output must not be cloned into the throwaway copy" ;; *) t_assert_ok true ;; esac
rm -rf "${_work}/.git" "${_work}/.gitignore" "${_work}/blob.bin" "${_work}/build" "${_work}/keep.txt"

t_case "a COPY_EXCLUDES entry that names a FILE is skipped, not just a directory"
_fixture "GUARD=on" "GUARD=off" yes .
mkdir -p "${_work}/linux/llm-stack"; printf 'x' > "${_work}/linux/llm-stack/ollama-binary.tar.zst"
printf 'find . -type f | LC_ALL=C sort > "%s/copied"\ngrep -q "GUARD=on" ./subject.sh\n' "${_tmp}" > "${_work}/t.sh"
t_assert_contains "$(_iso_run)" "bites" "the listing must come from a real, biting run"
case "$(cat "${_tmp}/copied")" in *"ollama-binary.tar.zst"*) t_assert_eq "file excluded" "file copied" \
  "an excluded FILE was still copied -- the skip only pruned dirnames" ;; *) t_assert_ok true ;; esac
rm -rf "${_work}/linux"

t_case "a copy that fails is a loud error, never a vacuous-bite verdict"
if [ "$(id -u)" != 0 ] && _posix_host "an unreadable file (chmod 000)"; then
_fixture "GUARD=on" "GUARD=off" yes .
printf 'secret\n' > "${_work}/unreadable"; chmod 000 "${_work}/unreadable"
_out="$(_iso_run)"; _code="$(_iso_rc)"
chmod 644 "${_work}/unreadable"; rm -f "${_work}/unreadable"
t_assert_eq "1" "${_code}" "an incomplete copy must fail the gate"
t_assert_contains "${_out}" "mirror_tree: could not copy" "the failure must name the copy, not the tests"
case "${_out}" in *"vacuous bite"*) t_assert_eq "no vacuous verdict" "vacuous verdict" \
  "disk trouble must not be reported as a test defect" ;; *) t_assert_ok true ;; esac
fi

# _child_probe <test body> [timeout]: one probe mutation whose test records a child's pid in ${_tmp}/gpid.
_child_probe() {
  _fixture "GUARD=on" "GUARD=off" yes .
  printf '%s\n' "$1" > "${_work}/t.sh"
  printf '[{"id":"probe","target":"subject.sh","find":"GUARD=on","replace":"GUARD=off","test":"bash ./t.sh","why":"probe","timeout":%s}]\n' \
    "${2:-300}" > "${_work}/m.json"
}
# _child_gone <why>: the recorded child is dead where process groups exist; it is killed and forgotten either way.
_child_gone() {
  if _posix_host "process groups (os.killpg)"; then
    t_assert_eq "dead" "$(t_pid_state "$(cat "${_tmp}/gpid" 2>/dev/null)")" "$1"
  fi
  kill -9 "$(cat "${_tmp}/gpid" 2>/dev/null)" 2>/dev/null; rm -f "${_tmp}/gpid"
}

t_case "a test that times out is killed as a TREE, its grandchildren with it"
# Spins only once mutated (else its baseline fails), and ends at 60 s: an orphaned endless spin held a core for 2.8 days.
_child_probe "$(printf 'grep -q "GUARD=on" ./subject.sh && exit 0\nsleep 60 &\necho $! > "%s/gpid"\nwhile [ "${SECONDS}" -lt 60 ]; do :; done' "${_tmp}")" 2
_t0="$(date +%s)"
_out="$(_iso_run)"
t_assert_contains "${_out}" "bites" "the spinning mutant times out, and a timeout counts as a bite"
t_assert_fails grep -q -e 'Traceback' <<<"${_out}"
# A sleeper the gate fails to kill holds the output pipe, so the gate waits out its 60 s and the check below finds it dead.
if _posix_host "process groups (os.killpg)"; then t_assert_ok test "$(( $(date +%s) - _t0 ))" -lt 40; fi
sleep 1
_child_gone "the sleeper grandchild must not survive the timeout"

t_case "a test that ends on its own leaves no child behind either"
# Off the test's pipes, like an orphaned Chrome: a child holding them would only delay the end, not outlive it.
_child_probe "$(printf 'sleep 60 >/dev/null 2>&1 &\necho $! > "%s/gpid"\ngrep -q "GUARD=on" ./subject.sh' "${_tmp}")"
t_assert_contains "$(_iso_run)" "bites"
_child_gone "a finished test's child must not outlive it"

t_case "a gate killed mid-test takes the running test's session with it"
_child_probe "$(printf 'sleep 60 >/dev/null 2>&1 &\necho $! > "%s/gpid"\nwait' "${_tmp}")" 120
TMPDIR="${_tmp}" "${PY}" "${GATE}" --manifest "${_work}/m.json" --root "${_work}" >/dev/null 2>&1 &
_gp=$!
t_wait_file "${_tmp}/gpid"
kill -TERM "${_gp}"; wait "${_gp}" 2>/dev/null
_child_gone "a SIGTERM'd gate left its test's child running"

# --- symlinks: the copy must neither dereference them nor let a write out ------

# _symlink_fixture <target> [inside|outside|dangling]: the test records what the copy holds and the outside file.
_symlink_fixture() {
  _fixture "GUARD=on" "GUARD=off" yes .
  printf 'GUARD=on\n' > "${_tmp}/outside.txt"
  printf 'GUARD=on\n' > "${_work}/inner.txt"
  case "${2:-inside}" in
    outside)  ln -sfn "${_tmp}/outside.txt" "${_work}/link" ;;
    dangling) ln -sfn no-such-file.txt "${_work}/link" ;;
    *)        ln -sfn inner.txt "${_work}/link" ;;
  esac
  printf 'not-run\n' > "${_tmp}/kind"
  printf 'not-run\n' > "${_tmp}/outside-witness"
  { printf 'if [ -L ./link ]; then echo symlink; elif [ -e ./link ]; then echo dereferenced; else echo absent; fi > "%s/kind"\n' "${_tmp}"
    printf 'cat "%s/outside.txt" > "%s/outside-witness"\n' "${_tmp}" "${_tmp}"
    printf 'grep -q "GUARD=on" ./subject.sh\n'
  } > "${_work}/t.sh"
  printf '[{"id":"probe","target":"%s","find":"GUARD=on","replace":"GUARD=off","test":"bash ./t.sh","why":"probe"}]\n' \
    "$1" > "${_work}/m.json"
}

t_case "the copy keeps a symlink AS a symlink instead of dereferencing it"
t_needs "real symlinks (ln -s copies under Git Bash)" t_posix_symlinks
_symlink_fixture subject.sh inside
t_assert_contains "$(_iso_run)" "bites" "the listing must come from a real, biting run"
t_assert_eq "symlink" "$(cat "${_tmp}/kind")" \
  "dereferencing pulls whatever the link points at -- a host binary, a device -- into a copy made once per commit"

t_case "a link that RESOLVES outside the tree is not copied into the workspace at all"
t_needs "real symlinks (ln -s copies under Git Bash)" t_posix_symlinks
_symlink_fixture subject.sh outside
t_assert_contains "$(_iso_run)" "bites" "the listing must come from a real, biting run"
t_assert_eq "absent" "$(cat "${_tmp}/kind")" \
  "keeping the link as a link still lets a test inside the copy read and write straight through it -- docs/.venv/bin/python IS /usr/bin/python3"
t_assert_eq "GUARD=on" "$(cat "${_tmp}/outside-witness")" \
  "and the outside file must be untouched WHILE the test runs, not merely afterwards"
t_assert_eq "GUARD=on" "$(cat "${_tmp}/outside.txt")"

t_case "a symlink is refused as a mutation target, so no write goes through it"
t_needs "real symlinks (ln -s copies under Git Bash)" t_posix_symlinks
_symlink_fixture link inside
_out="$(_iso_run 2>&1)"
t_assert_contains "${_out}" "target is a symlink" \
  "the copy holds the link, not the file: mutating it writes straight through to whatever it names"
t_assert_eq "1" "$(_iso_rc)" "a mutation that cannot be applied safely must fail the gate, not be skipped"

t_case "a DANGLING symlink is still refused as a symlink, not reported as missing"
t_needs "real symlinks (ln -s copies under Git Bash)" t_posix_symlinks
# os.path.exists() follows the link, so a dangling one would read as a stale entry.
_symlink_fixture link dangling
_out="$(_iso_run 2>&1)"
t_assert_contains "${_out}" "target is a symlink" "the link is the finding, not what it points at"
t_assert_eq 0 "$(printf '%s' "${_out}" | grep -c 'target missing')" "and it must not be misreported as a stale entry"
t_assert_eq "1" "$(_iso_rc)"

# Shards run in parallel, but every entry must still be proven alone.

# _shard_fixture <n> <survivor>: n entries; the survivor's test cannot fail, so a dropped shard shows.
_shard_fixture() {
  local n="$1" survivor="$2" entries="" id
  for id in $(seq 1 "${n}"); do
    printf 'GUARD=on\n' > "${_work}/s${id}.sh"
    if [ "${id}" = "${survivor}" ]; then
      printf 'true\n' > "${_work}/t${id}.sh"
    else
      printf 'grep -q "GUARD=on" "./s%s.sh"\n' "${id}" > "${_work}/t${id}.sh"
    fi
    entries="${entries}${entries:+,}$(printf '{"id":"probe.%s","target":"s%s.sh","find":"GUARD=on","replace":"GUARD=off","test":"bash ./t%s.sh","why":"probe %s"}' "${id}" "${id}" "${id}" "${id}")"
  done
  printf '[%s]\n' "${entries}" > "${_work}/m.json"
}
# The ids reported as biting, in id order: verdicts stream in completion order, each behind its [j/J] tag.
_bitten() {
  printf '%s\n' "$1" | sed -n 's/^\(\[[0-9]*\/[0-9]*\] \)\{0,1\}  bites  *probe\.\([0-9]*\).*/\2/p' \
    | sort -n | sed 's/^/probe./' | tr '\n' ' '
}

t_case "a parallel run proves every entry, and one survivor anywhere fails it"
_shard_fixture 8 6
_out="$(t_out _iso --jobs 4)"
t_assert_eq "1" "$(t_rc _iso --jobs 4)" "a survivor in ANY shard must fail the whole run"
t_assert_contains "${_out}" "probe.6 SURVIVED" \
  "the entry whose test cannot fail must be named, whichever shard drew it"
t_assert_eq "probe.1 probe.2 probe.3 probe.4 probe.5 probe.7 probe.8 " "$(_bitten "${_out}")" \
  "sharding must not thin the run: every other entry is still proven on its own"

t_case "every verdict carries its shard's tag, and the summary names failures in manifest order"
_shard_fixture 8 6
_out="$(t_out _iso --jobs 4)"
t_assert_eq "8" "$(printf '%s\n' "${_out}" | grep -c -E -e '^\[[1-4]/4\] ( +bites +probe\.[0-9]|FAIL: probe\.[0-9])' || true)" \
  "one tagged verdict per entry: a CI log that is cut off must still say which shard proved what"
t_assert_contains "${_out}" "FAILED: 1 of 8 entr(ies), in manifest order: probe.6"
_shard_fixture 8 0
t_assert_eq "0" "$(t_rc _iso --jobs 4)" "eight catchable mutations are eight bites"
t_assert_eq "probe.1 probe.2 probe.3 probe.4 probe.5 probe.6 probe.7 probe.8 " "$(_bitten "$(t_out _iso --jobs 4)")"

t_case "--shard K/N slices the selection so N runs prove every entry exactly once"
_shard_fixture 8 0
for _n in 1 3 5; do
  _union=""
  for _k in $(seq 0 $((_n - 1))); do _union+="$(_bitten "$(t_out _iso --jobs 2 --shard "${_k}/${_n}")")"; done
  t_assert_eq "probe.1 probe.2 probe.3 probe.4 probe.5 probe.6 probe.7 probe.8 " \
    "$(printf '%s' "${_union}" | tr ' ' '\n' | sed '/^$/d' | sort -t. -k2 -n | tr '\n' ' ')" \
    "the ${_n} slices must partition the manifest: no entry twice, none dropped"
done
t_assert_contains "$(t_out _iso --shard 1/3)" "(shard 1/3: 3 entr(ies))" "the header names the slice it proved"
for _bad in 3/3 -1/3 1 x/y; do
  t_assert_eq "2" "$(t_rc _iso --shard "${_bad}")" "--shard ${_bad} is a usage error, not an empty green run"
done

t_case "a run killed mid-way has already printed the verdicts it reached"
# CI kills a job at its timeout; a block-buffered report took every finding with it (2026-09-23).
printf 'GUARD=on\n' > "${_work}/s1.sh"; printf 'GUARD=on\n' > "${_work}/s2.sh"
printf 'grep -q "GUARD=on" ./s1.sh\n' > "${_work}/t1.sh"
printf 'grep -q "GUARD=on" ./s2.sh && exit 0\nsleep 30 &\necho $! > "%s/gpid"\nwait\n' "${_tmp}" > "${_work}/t2.sh"
printf '[%s,%s]\n' \
  '{"id":"probe.1","target":"s1.sh","find":"GUARD=on","replace":"GUARD=off","test":"bash ./t1.sh","why":"probe 1"}' \
  '{"id":"probe.2","target":"s2.sh","find":"GUARD=on","replace":"GUARD=off","test":"bash ./t2.sh","why":"probe 2"}' \
  > "${_work}/m.json"
TMPDIR="${_tmp}" "${PY}" "${GATE}" --manifest "${_work}/m.json" --root "${_work}" --jobs 1 > "${_tmp}/cut.log" 2>&1 &
_gp=$!
for _ in $(seq 150); do
  if grep -q -e 'bites   probe.1' "${_tmp}/cut.log"; then break; fi
  sleep 0.1
done
t_assert_ok kill -0 "${_gp}"
# Read before the kill: the gate's SIGTERM handler exits cleanly, and a clean exit flushes what a hard kill loses.
_live="$(cat "${_tmp}/cut.log")"
kill "${_gp}" 2>/dev/null; wait "${_gp}" 2>/dev/null
t_assert_contains "${_live}" "=== mutation gate: can these tests fail? ===" \
  "the header must not wait for the end"
t_assert_contains "${_live}" "bites   probe.1" \
  "the verdict reached before the kill must be in the log while the run is still going"
kill -9 "$(cat "${_tmp}/gpid" 2>/dev/null)" 2>/dev/null
rm -rf "${_tmp}/gpid" "${_tmp}/cut.log" "${_tmp}"/mutation-gate-*

t_case "a parallel run mutates its own mirrors only, never the tree it was pointed at"
_shard_fixture 8 0
_before="$(_snapshot)"
t_assert_eq "0" "$(t_rc _iso --jobs 4)"
t_assert_eq "${_before}" "$(_snapshot)" \
  "one shard per mirror is the whole point -- shards sharing a tree would mutate each other's subjects"

t_case "--jobs never exceeds the number of entries, so a single id makes one copy"
_fixture "GUARD=on" "GUARD=off" yes .
t_assert_contains "$(t_out _iso --jobs 16)" "bites" "a cap larger than the work must not change the verdict"
t_assert_eq "" "$(find "${_tmp}" -maxdepth 1 -name 'mutation-gate-*' -print)" \
  "and every mirror a parallel run made must be gone afterwards"

# Entries 1 and 3 wait for each other: dealt round-robin over two mirrors they queue on one and meet nobody.
t_case "a free mirror takes the next entry, so slow entries never queue behind each other"
_shard_fixture 4 0
_meet="$(mktemp -d)"
for _slow in 1 3; do
  printf 'source %q\nmeet_peers %q t%s 2 20 >> %q\ngrep -q "GUARD=on" "./s%s.sh"\n' \
    "${TESTS_DIR}/meet.sh" "${_meet}" "${_slow}" "${_meet}.said" "${_slow}" > "${_work}/t${_slow}.sh"
done
t_assert_eq "0" "$(t_rc _iso --jobs 2)"
t_assert_eq "met" "$(sort -u "${_meet}.said")" "both slow entries must be running at once"
rm -rf "${_meet}" "${_meet}.said"

t_case "mirrors are capped at a quarter of the temp filesystem's free space, never below one"
t_assert_eq "4 1 1" "$(cd "${REPO}/docs/scripts" && "${PY}" -c 'import verify_mutations as v; print(v.mirror_cap(100, 1600), v.mirror_cap(100, 100), v.mirror_cap(0, 0))')"

t_case "the default job count is the CPUs this process may use"
t_assert_eq "3" "$(cd "${REPO}/docs/scripts" && PYTHON_CPU_COUNT=3 "${PY}" -c 'import verify_mutations as v; print(v.DEFAULT_JOBS)')"
t_assert_eq "12" "$(cd "${REPO}/docs/scripts" && PYTHON_CPU_COUNT=12 "${PY}" -c 'import verify_mutations as v; print(v.DEFAULT_JOBS)')" \
  "no cap below the CPU count: a fixed 8 left 24 of 32 cores idle"

t_summary
