#!/usr/bin/env bash
# Tests for docs/scripts/verify_mutations.py. It neuters a guarantee to check a
# test can fail, so the cases that matter most are that the tree it was pointed at
# comes back byte-identical (a build may be reading it), that --in-place -- the
# opt-out these fixtures use -- still edits in place and restores, that no write
# escapes the copy through a symlink, and that the two production call sites never
# pass it.
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

t_case "--changed also selects by the TEST an entry runs, not only by target"
# A commit that only weakens tests/t.sh touches no target; matching the test
# path is what makes the gate re-verify the guarantee that test carries.
_fixture "GUARD=on" "GUARD=off" yes .
printf '#!/usr/bin/env bash\nprintf "t.sh\\n"\n' > "${_work}/bin/git"
t_assert_contains "$(PATH="${_work}/bin:${PATH}" t_out _iso --changed)" "bites" \
  "an entry whose test file is in the diff must be selected"

# --- --stale-check: the half of an entry that ROTS, without running one test ---
# 378 entries in ~0.06s, which is what makes a whole-manifest pass affordable in
# a hook. What it must never do is read as a substitute for the gate.

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
# It answers 'does this edit still apply', never 'can the test fail'. A caller that
# ran only this and called it coverage would be the false green this tool exists for.
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
_fixture "GUARD=on" "GUARD=off" yes .
chmod +x "${_work}/subject.sh"
printf 'test -x ./subject.sh || exit 1\ngrep -q "GUARD=on" ./subject.sh\n' > "${_work}/t.sh"
t_assert_contains "$(_iso_run)" "bites" \
  "a mode-losing copy makes every shell test fail for the wrong reason, not for the mutation"
t_assert_eq "0" "$(_iso_rc)" "the executable subject must still produce an honest bite"

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

# --- the copy asks git, copies files as carefully as dirs, and fails loudly ---
#
# All three were found at once on 2026-09-04: a 1.5 GB gitignored tarball was
# copied into a 3 GB tmpfs on every run (COPY_EXCLUDES only ever pruned
# DIRECTORIES, so listing the file there changed nothing), the copy hit ENOSPC,
# `except OSError: pass` produced 0-byte test files, pytest collected nothing,
# and nineteen entries were reported as vacuous bites -- a verdict about disk
# space wearing the clothes of a verdict about the tests.

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

if [ "$(id -u)" != 0 ]; then
t_case "a copy that fails is a loud error, never a vacuous-bite verdict"
_fixture "GUARD=on" "GUARD=off" yes .
printf 'secret\n' > "${_work}/unreadable"; chmod 000 "${_work}/unreadable"
_out="$(_iso_run)"; _code="$(_iso_rc)"
chmod 644 "${_work}/unreadable"; rm -f "${_work}/unreadable"
t_assert_eq "1" "${_code}" "an incomplete copy must fail the gate"
t_assert_contains "${_out}" "mirror_tree: could not copy" "the failure must name the copy, not the tests"
case "${_out}" in *"vacuous bite"*) t_assert_eq "no vacuous verdict" "vacuous verdict" \
  "disk trouble must not be reported as a test defect" ;; *) t_assert_ok true ;; esac
fi

t_case "a test that times out is killed as a TREE, its grandchildren with it"
# A test that forks a sleeper, records its pid, then spins past the entry's
# timeout. Killing only the shell left the sleeper (and, in the real gate, a
# whole pytest) running: one such orphan burned CPU for twenty minutes.
_fixture "GUARD=on" "GUARD=off" yes .
# Green unmutated, spinning once the guard is gone: a probe that ALWAYS spins
# fails its own baseline and is reported vacuous before the kill is exercised.
printf 'grep -q "GUARD=on" ./subject.sh && exit 0\nsleep 60 &\necho $! > "%s/gpid"\nwhile :; do :; done\n' "${_tmp}" > "${_work}/t.sh"
printf '[{"id":"probe","target":"subject.sh","find":"GUARD=on","replace":"GUARD=off","test":"bash ./t.sh","why":"probe","timeout":2}]\n' > "${_work}/m.json"
_out="$(_iso_run)"
t_assert_contains "${_out}" "bites" "the spinning mutant times out, and a timeout counts as a bite"
sleep 1
_g="$(cat "${_tmp}/gpid" 2>/dev/null)"
t_assert_eq "dead" "$( kill -0 "${_g}" 2>/dev/null && echo alive || echo dead )" "the sleeper grandchild must not survive the timeout"
kill -9 "${_g}" 2>/dev/null; rm -f "${_tmp}/gpid"

# --- symlinks: the copy must neither dereference them nor let a write out ------

# A tree with a `link`, mutating <target>. $2 places the link: "inside" points it
# at a sibling of the subject, "outside" at a file the tree does not contain,
# "dangling" at a name inside the tree that does not exist. The test records what
# the COPY holds -- the only place the symlink handling is observable -- and what
# the outside file said WHILE it ran.
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
_symlink_fixture subject.sh inside
t_assert_contains "$(_iso_run)" "bites" "the listing must come from a real, biting run"
t_assert_eq "symlink" "$(cat "${_tmp}/kind")" \
  "dereferencing pulls whatever the link points at -- a host binary, a device -- into a copy made once per commit"

t_case "a link that RESOLVES outside the tree is not copied into the workspace at all"
_symlink_fixture subject.sh outside
t_assert_contains "$(_iso_run)" "bites" "the listing must come from a real, biting run"
t_assert_eq "absent" "$(cat "${_tmp}/kind")" \
  "keeping the link as a link still lets a test inside the copy read and write straight through it -- docs/.venv/bin/python IS /usr/bin/python3"
t_assert_eq "GUARD=on" "$(cat "${_tmp}/outside-witness")" \
  "and the outside file must be untouched WHILE the test runs, not merely afterwards"
t_assert_eq "GUARD=on" "$(cat "${_tmp}/outside.txt")"

t_case "a symlink is refused as a mutation target, so no write goes through it"
_symlink_fixture link inside
_out="$(_iso_run 2>&1)"
t_assert_contains "${_out}" "target is a symlink" \
  "the copy holds the link, not the file: mutating it writes straight through to whatever it names"
t_assert_eq "1" "$(_iso_rc)" "a mutation that cannot be applied safely must fail the gate, not be skipped"

t_case "a DANGLING symlink is still refused as a symlink, not reported as missing"
# os.path.exists() follows the link, so a link to nothing looks like an absent
# target -- which sends the reader hunting for a stale manifest entry instead of
# the symlink that would have let a write escape the copy.
_symlink_fixture link dangling
_out="$(_iso_run 2>&1)"
t_assert_contains "${_out}" "target is a symlink" "the link is the finding, not what it points at"
t_assert_eq 0 "$(printf '%s' "${_out}" | grep -c 'target missing')" "and it must not be misreported as a stale entry"
t_assert_eq "1" "$(_iso_rc)"

# --- shards: the run is parallel, the proof is still one mutation at a time ----
# 244 entries over 33 suites cost 8m47s serially, which is what kept the hook's
# sample at six. Shards buy that back only if every entry is still proven alone.

# $1 subjects, each with its own mutation and its own test; subject $2 gets a
# test that CANNOT fail, so a run that drops a shard reports a green it did not earn.
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
_bitten() { printf '%s\n' "$1" | sed -n 's/^  bites  *\(probe\.[0-9]*\).*/\1/p' | tr '\n' ' '; }

t_case "a parallel run proves every entry, and one survivor anywhere fails it"
_shard_fixture 8 6
_out="$(t_out _iso --jobs 4)"
t_assert_eq "1" "$(t_rc _iso --jobs 4)" "a survivor in ANY shard must fail the whole run"
t_assert_contains "${_out}" "probe.6 SURVIVED" \
  "the entry whose test cannot fail must be named, whichever shard drew it"
t_assert_eq "probe.1 probe.2 probe.3 probe.4 probe.5 probe.7 probe.8 " "$(_bitten "${_out}")" \
  "sharding must not thin the run: every other entry is still proven on its own"

t_case "the report reads in manifest order, not in the order the shards finished"
_shard_fixture 8 0
_out="$(t_out _iso --jobs 4)"
t_assert_eq "0" "$(t_rc _iso --jobs 4)" "eight catchable mutations are eight bites"
t_assert_eq "probe.1 probe.2 probe.3 probe.4 probe.5 probe.6 probe.7 probe.8 " "$(_bitten "${_out}")"

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

t_summary
