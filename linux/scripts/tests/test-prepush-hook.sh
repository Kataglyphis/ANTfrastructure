#!/usr/bin/env bash
# The hook's order, flags and abort paths over a stub git, with stub and real gates; test-mutation-push.sh pushes for real. See docs/code-quality-tooling.md#the-pre-push-hook
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/gate-tree.sh"
HOOK="${TESTS_DIR}/../../host-config/git-hooks/pre-push"
REAL_GATE="${TESTS_DIR}/../../../docs/scripts/verify_mutations.py"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
# The default is under test, so a cap the pushing shell exports must not reach the hook.
unset PREPUSH_MUTATION_JOBS
_root="${_work}/root"
_ARGV="${_work}/argv.txt"
mkdir -p "${_root}/docs/scripts" "${_work}/bin"

cat > "${_work}/bin/git" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == *"cat-file -e 1111"* ]] && exit 1
[[ "$*" == *"--verify origin/develop"* ]] && exit "${HOOK_TEST_NO_DEVELOP:-0}"
case "$*" in
  *"rev-parse --show-toplevel"*) printf '%s\n' "${HOOK_TEST_ROOT}" ;;
  *"status --porcelain"*) [ -z "${HOOK_TEST_DIRTY:-}" ] || printf ' M %s\n' "${HOOK_TEST_DIRTY}" ;;
esac
STUB
chmod +x "${_work}/bin/git"

_stub_gate() { gate_stub_recorder "${_root}/docs/scripts/verify_mutations.py"; }
mkdir -p "${_root}/linux/scripts/tests"
printf 'echo docnumbers >> "${HOOK_TEST_ARGV}.cheap"; exit "${HOOK_TEST_DOCS_RC:-0}"\n' > "${_root}/linux/scripts/tests/test-doc-numbers.sh"
printf 'import os, sys\nopen(os.environ["HOOK_TEST_ARGV"] + ".cheap", "a").write("comments\\n")\nsys.exit(int(os.environ.get("HOOK_TEST_COMMENT_RC", "0")))\n' > "${_root}/linux/scripts/verify_comment_size.py"

_run_hook() {  # <staleness rc> <gate rc>; prints the hook's output then rc=<n>
  local _o _rc
  rm -f "${_ARGV}" "${_ARGV}.cheap"
  _o="$(PATH="${_work}/bin:${PATH}" HOOK_TEST_ROOT="${_root}" HOOK_TEST_ARGV="${_ARGV}" \
        HOOK_TEST_STALE_RC="${1:-0}" HOOK_TEST_GATE_RC="${2:-0}" bash "${HOOK}" 2>&1 </dev/null)"; _rc=$?
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
t_assert_contains "$(_call 2)" "--push-range" "then the entries the push actually adds"
t_assert_contains "$(_call 2)" "--delegate-chrome" "Chrome suites stall on the build host and CI proves them"

t_case "the cheap checks run on every push, before any mutation, and each stops it"
t_assert_eq "docnumbers comments" "$(tr '\n' ' ' < "${_ARGV}.cheap" | sed 's/ $//')" "a rebase moves both without a commit hook firing"
_out="$(HOOK_TEST_DOCS_RC=1 _run_hook 0 0)"
t_assert_contains "${_out}" "rc=1"
t_assert_contains "${_out}" "derived doc numbers are STALE"
t_assert_eq "0" "$(_calls)" "no mutation runs after a cheap refusal"
_out="$(HOOK_TEST_COMMENT_RC=1 _run_hook 0 0)"
t_assert_contains "${_out}" "rc=1"
t_assert_contains "${_out}" "over one line"
t_assert_eq "0" "$(_calls)" "no mutation runs after a cheap refusal"

t_case "uncommitted paths are named, and a clean tree is not"
_stub_gate
t_assert_contains "$(HOOK_TEST_DIRTY=a.sh _run_hook 0 0)" "1 uncommitted path(s)" "the checks read a tree the push does not carry"
t_assert_eq "0" "$(_run_hook 0 0 | grep -c uncommitted)"
_run_hook 0 0 >/dev/null

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

t_case "the gate picks its own job count, one per CPU, and PREPUSH_MUTATION_JOBS caps it"
t_assert_eq "0" "$(_call 2 | grep -c -e '--jobs' || true)" "a fixed 4 left 28 of 32 cores idle through a 10-minute push"
rm -f "${_ARGV}"
PATH="${_work}/bin:${PATH}" HOOK_TEST_ROOT="${_root}" HOOK_TEST_ARGV="${_ARGV}" \
  HOOK_TEST_STALE_RC=0 HOOK_TEST_GATE_RC=0 PREPUSH_MUTATION_JOBS=1 bash "${HOOK}" >/dev/null 2>&1 </dev/null
t_assert_contains "$(_call 2)" "--jobs 1"

t_case "the gate grades each pushed ref from the tip git hands the hook"
_zero=0000000000000000000000000000000000000000
_push() {  # <remote sha> [<local sha>]: one pushed ref on stdin, as git writes it
  rm -f "${_ARGV}"
  printf 'refs/heads/develop %s refs/heads/develop %s\n' "${2:-abc123}" "$1" | PATH="${_work}/bin:${PATH}" \
    HOOK_TEST_ROOT="${_root}" HOOK_TEST_ARGV="${_ARGV}" HOOK_TEST_STALE_RC=0 HOOK_TEST_GATE_RC=0 \
    bash "${HOOK}" 2>&1
}
_push 1282f76d >/dev/null
t_assert_contains "$(_call 2)" "--push-range 1282f76d...abc123" "develop is what the push updates; main lags it by hundreds of entries"
_push "${_zero}" >/dev/null
t_assert_contains "$(_call 2)" "--push-range origin/develop...abc123" "a new ref grades what it adds to develop"
export HOOK_TEST_NO_DEVELOP=1
_push "${_zero}" >/dev/null
t_assert_contains "$(_call 2)" "--push-range origin/main...abc123" "and main only where no develop exists"
unset HOOK_TEST_NO_DEVELOP

t_case "a remote tip this clone has not fetched refuses before any proof"
_out="$(_push 1111aaaa; echo "rc=$?")"
t_assert_contains "${_out}" "rc=1" "git rejects this push anyway, after the proofs"
t_assert_contains "${_out}" "refused before any proof"
t_assert_eq "0" "$(_calls)"

t_case "a deleted ref proves nothing, and every other pushed ref is graded"
_push 1282f76d "${_zero}" >/dev/null
t_assert_eq "1" "$(_calls)" "only the staleness pass"
rm -f "${_ARGV}"
printf 'refs/heads/a aaa refs/heads/a 1282f76d\nrefs/heads/b bbb refs/heads/b 2222bbbb\n' | PATH="${_work}/bin:${PATH}" \
  HOOK_TEST_ROOT="${_root}" HOOK_TEST_ARGV="${_ARGV}" HOOK_TEST_STALE_RC=0 HOOK_TEST_GATE_RC=0 bash "${HOOK}" >/dev/null 2>&1
t_assert_contains "$(_call 2)" "--push-range 1282f76d...aaa --push-range 2222bbbb...bbb" "the first ref alone would leave the second unproved"

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
  bash "${HOOK}" >/dev/null 2>&1 </dev/null
t_assert_eq "2" "$(_calls)" "both gate calls ran"
t_assert_eq "0" "$(grep -c 'GIT_' "${_ARGV}")" "a GIT_* variable reached a gate; its fixtures would act on the real repository"
_stub_gate

# Only the real gate proves the hook stops a push over an entry that no longer applies.

_real_rig() {  # <find string planted in the manifest>
  cp "${REAL_GATE}" "${REAL_GATE%/*}/mutation_parse.py" "${REAL_GATE%/*}/mutation_shards.py" "${REAL_GATE%/*}/mutation_push.py" "${_root}/docs/scripts/"
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
cp "${REAL_GATE}" "${REAL_GATE%/*}/mutation_parse.py" "${REAL_GATE%/*}/mutation_shards.py" "${REAL_GATE%/*}/mutation_push.py" "${_root}/docs/scripts/"
printf 'GUARD=on\n' > "${_root}/subject.sh"
printf '[{"id":"probe.one","target":"subject.sh","find":"GUARD=on","replace":"GUARD=off","test":"false","why":"probe"}]\n' \
  > "${_root}/docs/scripts/mutations.json"
_out="$(_run_hook 0 0)"
t_assert_contains "${_out}" "every recorded mutation still applies"
t_assert_contains "${_out}" "rc=0"

t_summary
