#!/usr/bin/env bash
# The push hook is the only thing between a SAMPLED commit gate and CI. Two steps
# carry that: staleness over the WHOLE manifest, then the real gate over what the
# push adds. Both are pinned end to end -- stubbed git and a stubbed gate for the
# argv and the abort paths, the real gate for the verdict.
# docs/code-quality-tooling.md#the-pre-push-hook
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
# Scoping it to the diff would leave the other ~370 entries exactly as invisible
# between a commit and CI as they were before this hook existed.
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

# --- the REAL gate: the verdict, not just the plumbing ------------------------
# A stub proves the hook calls something. Only the real gate proves the hook
# STOPS a push over a mutation entry that no longer applies.

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
# `"test": "false"` would fail every entry if the pass ran it; the healthy verdict
# is the evidence that it did not.
cp "${REAL_GATE}" "${_root}/docs/scripts/verify_mutations.py"
printf 'GUARD=on\n' > "${_root}/subject.sh"
printf '[{"id":"probe.one","target":"subject.sh","find":"GUARD=on","replace":"GUARD=off","test":"false","why":"probe"}]\n' \
  > "${_root}/docs/scripts/mutations.json"
_out="$(_run_hook 0 0)"
t_assert_contains "${_out}" "every recorded mutation still applies"
t_assert_contains "${_out}" "rc=0"

t_summary
