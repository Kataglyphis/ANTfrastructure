#!/usr/bin/env bash
# Staleness over the whole manifest, then the real gate over the push; see docs/code-quality-tooling.md#the-pre-push-hook
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/gate-tree.sh"
HOOK="${TESTS_DIR}/../../host-config/git-hooks/pre-push"
REAL_GATE="${TESTS_DIR}/../../../docs/scripts/verify_mutations.py"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
_root="${_work}/root"
_ARGV="${_work}/argv.txt"
mkdir -p "${_root}/docs/scripts" "${_work}/bin"

cat > "${_work}/bin/git" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == *"cat-file -e 1111"* ]] && exit 1
case "$*" in *"rev-parse --show-toplevel"*) printf '%s\n' "${HOOK_TEST_ROOT}" ;; esac
STUB
chmod +x "${_work}/bin/git"

_stub_gate() { gate_stub_recorder "${_root}/docs/scripts/verify_mutations.py"; }

_run_hook() {  # <staleness rc> <gate rc>; prints the hook's output then rc=<n>
  local _o _rc
  rm -f "${_ARGV}"
  _o="$(PATH="${_work}/bin:${PATH}" HOOK_TEST_ROOT="${_root}" HOOK_TEST_ARGV="${_ARGV}" \
        HOOK_TEST_STALE_RC="${1:-0}" HOOK_TEST_GATE_RC="${2:-0}" bash "${HOOK}" 2>&1)"; _rc=$?
  printf '%s\nrc=%s\n' "${_o}" "${_rc}"
}
_call() { sed -n "$1p" "${_ARGV}"; }
_calls() { grep -c . "${_ARGV}" 2>/dev/null || echo 0; }

_stub_gate

t_case "both steps run, staleness first, and the push is let through"
_out="$(_run_hook 0 0)"
t_assert_contains "${_out}" "rc=0"
t_assert_contains "${_out}" "pre-push: OK"
t_assert_eq "2" "$(_calls)" "one staleness pass and one real gate run"
t_assert_contains "$(_call 1)" "--stale-check" "the cheap whole-manifest pass goes first"
t_assert_contains "$(_call 2)" "--changed" "then the entries the push actually adds"

t_case "the staleness pass covers the WHOLE manifest, not the diff"
# Scoped to the diff, it would leave every other entry unchecked between a commit and CI.
t_assert_eq "--stale-check" "$(_call 1)" "no --only, no --changed: every recorded entry is read"

t_case "neither call opts out of isolation"
t_assert_eq "0" "$(grep -c -e '--in-place' "${_ARGV}")" \
  "the hook runs against the live working tree a build may be reading as a context"

t_case "a rotted manifest entry aborts the push"
_out="$(_run_hook 1 0)"
t_assert_contains "${_out}" "rc=1" "printing is not enough; the push must stop"
t_assert_contains "${_out}" "no longer applies"
t_assert_eq "1" "$(_calls)" "and the expensive step must not run after the cheap one refused"

t_case "a surviving mutation aborts the push"
_out="$(_run_hook 0 1)"
t_assert_contains "${_out}" "rc=1"
t_assert_contains "${_out}" "SURVIVED"

t_case "the jobs cap is the documented escape hatch, and defaults to 4"
t_assert_contains "$(_call 2)" "--jobs 4" "eight mirrors of the tree is a lot to hold during a live build"
rm -f "${_ARGV}"
PATH="${_work}/bin:${PATH}" HOOK_TEST_ROOT="${_root}" HOOK_TEST_ARGV="${_ARGV}" \
  HOOK_TEST_STALE_RC=0 HOOK_TEST_GATE_RC=0 PREPUSH_MUTATION_JOBS=1 bash "${HOOK}" >/dev/null 2>&1
t_assert_contains "$(_call 2)" "--jobs 1"

t_case "the gate counts from the remote's tip that git hands the hook, not from origin/main"
_zero=0000000000000000000000000000000000000000
_push() {  # <remote sha>: one pushed ref on stdin, as git writes it
  rm -f "${_ARGV}"
  printf 'refs/heads/develop abc123 refs/heads/develop %s\n' "$1" | PATH="${_work}/bin:${PATH}" \
    HOOK_TEST_ROOT="${_root}" HOOK_TEST_ARGV="${_ARGV}" HOOK_TEST_STALE_RC=0 HOOK_TEST_GATE_RC=0 \
    bash "${HOOK}" >/dev/null 2>&1
}
_push 740b9eba
t_assert_contains "$(_call 2)" "--base 740b9eba" "develop is what the push updates; main lags it by hundreds of entries"
_push "${_zero}"
t_assert_contains "$(_call 2)" "--base origin/main" "a new remote ref has no tip to count from"
_push 1111aaaa
t_assert_contains "$(_call 2)" "--base origin/main" "a tip this clone has not fetched would make the diff fail and select nothing"

t_case "git's hook environment never reaches a gate"
# See docs/failure-modes.md#a-push-leaves-the-repo-bare-corebare-and-coreworktree-do-not-make-sense
cat > "${_root}/docs/scripts/verify_mutations.py" <<'STUB'
import os
import pathlib

leaked = [k for k in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX") if k in os.environ]
record = pathlib.Path(os.environ["HOOK_TEST_ARGV"])
record.write_text(record.read_text() + " ".join(leaked) + "|\n" if record.exists() else " ".join(leaked) + "|\n")
STUB
rm -f "${_ARGV}"
PATH="${_work}/bin:${PATH}" HOOK_TEST_ROOT="${_root}" HOOK_TEST_ARGV="${_ARGV}" \
  GIT_DIR=/nonexistent/gitdir GIT_WORK_TREE=/nonexistent GIT_INDEX_FILE=/nonexistent/index GIT_PREFIX=sub/ \
  bash "${HOOK}" >/dev/null 2>&1
t_assert_eq "2" "$(_calls)" "both gate calls ran"
t_assert_eq "0" "$(grep -c 'GIT_' "${_ARGV}")" "a GIT_* variable reached a gate; its fixtures would act on the real repository"
_stub_gate

# Only the real gate proves the hook stops a push over an entry that no longer applies.

_real_rig() {  # <find string planted in the manifest>
  cp "${REAL_GATE}" "${_root}/docs/scripts/verify_mutations.py"
  printf 'GUARD=on\n' > "${_root}/subject.sh"
  printf '[{"id":"probe.one","target":"subject.sh","find":"%s","replace":"GUARD=off","test":"true","why":"probe"}]\n' \
    "$1" > "${_root}/docs/scripts/mutations.json"
}

t_case "the real gate, driven by the real hook, passes a manifest that still applies"
_real_rig "GUARD=on"
_out="$(_run_hook 0 0)"
t_assert_contains "${_out}" "rc=0"
t_assert_contains "${_out}" "every recorded mutation still applies"

t_case "the real gate, driven by the real hook, STOPS a push over a rotted entry"
_real_rig "GUARD=renamed-away"
_out="$(_run_hook 0 0)"
t_assert_contains "${_out}" "rc=1" "this is the rot class the repo keeps hitting; it must block"
t_assert_contains "${_out}" "probe.one" "and it must name the entry that rotted"

t_case "the real staleness pass runs no test, so it costs a read per entry"
# `"test": "false"` would fail every entry if the pass ran it, so a healthy verdict proves it did not.
cp "${REAL_GATE}" "${_root}/docs/scripts/verify_mutations.py"
printf 'GUARD=on\n' > "${_root}/subject.sh"
printf '[{"id":"probe.one","target":"subject.sh","find":"GUARD=on","replace":"GUARD=off","test":"false","why":"probe"}]\n' \
  > "${_root}/docs/scripts/mutations.json"
_out="$(_run_hook 0 0)"
t_assert_contains "${_out}" "every recorded mutation still applies"
t_assert_contains "${_out}" "rc=0"

t_summary
