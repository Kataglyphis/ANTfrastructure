#!/usr/bin/env bash
# The commit hook's mutation step is SAMPLED, and a sample must never read as
# full coverage. Pins the plan through --print-mutation-plan AND the hook's real
# block end to end -- stubbed git, stubbed gate recording its argv -- so the
# notice, its two numbers and the abort on a surviving mutation are all load-bearing.
# docs/code-quality-tooling.md#the-pre-commit-hooks-cost-budget
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
HOOK="${TESTS_DIR}/../../host-config/git-hooks/pre-commit"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

python3 - "${_work}/manifest.json" <<'PY'
import json
import sys

hot = [{"id": "hot.e%02d" % n, "target": "a/hot.conf", "find": "x", "replace": "y",
        "test": "true", "why": "fixture"} for n in range(10)]
cold = [{"id": "cold.only", "target": "a/cold.conf", "find": "x", "replace": "y",
         "test": "true", "why": "fixture"}]
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(hot + cold, fh)
PY
printf 'a/hot.conf\n' > "${_work}/hot.txt"
printf 'a/hot.conf\na/cold.conf\n' > "${_work}/both.txt"
printf 'a/untracked-by-any-entry.conf\n' > "${_work}/none.txt"

_plan() { bash "${HOOK}" --print-mutation-plan "$1" "${_work}/manifest.json" "$2"; }

t_case "the cap cuts the run: 10 matched entries, cap 3, three ids"
t_assert_eq "plan 3 10" "$(_plan 3 "${_work}/hot.txt" | head -1)"
t_assert_eq "3" "$(_plan 3 "${_work}/hot.txt" | tail -n +2 | grep -c .)"

t_case "the header reports MATCHED, not the cut size — the number the notice needs"
t_assert_eq "plan 6 11" "$(_plan 6 "${_work}/both.txt" | head -1)"

t_case "newest first: the last manifest entry for a staged target runs first"
t_assert_eq "cold.only" "$(_plan 3 "${_work}/both.txt" | sed -n '2p')"
t_assert_eq "hot.e09" "$(_plan 3 "${_work}/both.txt" | sed -n '3p')"

t_case "cap 0 is uncapped"
t_assert_eq "plan 10 10" "$(_plan 0 "${_work}/hot.txt" | head -1)"

t_case "a staged file no entry targets selects nothing"
t_assert_eq "plan 0 0" "$(_plan 6 "${_work}/none.txt" | head -1)"

_NOTICE_SRC="$(t_fn_src "${HOOK}" _mutation_notice)" || exit 1
eval "${_NOTICE_SRC}"

t_case "a cut run SAYS it sampled, and names both numbers"
t_assert_contains "$(_mutation_notice 6 132)" "SAMPLED 6 of 132"
t_case "a cut run never reads as full coverage"
t_assert_contains "$(_mutation_notice 6 132)" "NOT full coverage"
t_case "an uncut run does not claim to have sampled"
t_assert_fails grep -q -e 'SAMPLED' <<<"$(_mutation_notice 5 5)"
t_assert_contains "$(_mutation_notice 5 5)" "all 5 entries"

t_case "the hook still names the gate it runs, so the registry's hook tier stays true"
t_assert_ok grep -q -F -e 'docs/scripts/verify_mutations.py' "${HOOK}"

# End-to-end rig: the hook cds into a sandbox root, so git, the fast preflight and
# the mutation gate are all stubs there; the gate stub records the argv it was
# handed, which is the only evidence of what the notice's numbers describe.
_root="${_work}/root"
_ARGV="${_work}/argv.txt"
mkdir -p "${_root}/linux/scripts" "${_root}/docs/scripts" "${_work}/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "${_root}/linux/scripts/preflight.sh"
cat > "${_work}/bin/git" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"rev-parse --show-toplevel"*) printf '%s\n' "${HOOK_TEST_ROOT}" ;;
  *"--cached --name-only"*) cat "${HOOK_TEST_STAGED}" ;;
esac
STUB
chmod +x "${_work}/bin/git"
cat > "${_root}/docs/scripts/verify_mutations.py" <<'STUB'
import os
import sys

with open(os.environ["HOOK_TEST_ARGV"], "w", encoding="utf-8") as fh:
    fh.write("\n".join(sys.argv[1:]))
sys.exit(int(os.environ["HOOK_TEST_GATE_RC"]))
STUB

_run_hook() {
  rm -f "${_ARGV}"
  PATH="${_work}/bin:${PATH}" HOOK_TEST_ROOT="${_root}" HOOK_TEST_STAGED="$2" \
    HOOK_TEST_ARGV="${_ARGV}" HOOK_TEST_GATE_RC="${3-0}" \
    PRECOMMIT_MUTATION_CAP="$1" PRECOMMIT_MUTATION_MANIFEST="${_work}/manifest.json" \
    bash "${HOOK}" 2>&1
}
_gate_ids() { grep -c -v -x -e '--only' "${_ARGV}"; }
_notice_ran() { sed -n 's/.*SAMPLED \([0-9]*\) of [0-9]*.*/\1/p' <<<"$1"; }

t_case "capped, end to end: the SAMPLED notice reaches the developer's terminal"
_out="$(_run_hook 3 "${_work}/both.txt")"
t_assert_contains "${_out}" "SAMPLED 3 of 11"
t_assert_contains "${_out}" "NOT full coverage"
t_assert_contains "${_out}" "pre-commit: OK"

t_case "the sample size the notice states is the number of ids the gate was handed"
t_assert_eq "3" "$(_gate_ids)"
t_assert_eq "$(_gate_ids)" "$(_notice_ran "${_out}")"

t_case "uncapped, end to end: nothing on the terminal claims a sample"
_out="$(_run_hook 0 "${_work}/hot.txt")"
t_assert_fails grep -q -e 'SAMPLED' <<<"${_out}"
t_assert_contains "${_out}" "all 10 entries"
t_assert_eq "10" "$(_gate_ids)"

t_case "no entry targets a staged file: the gate is not run and nothing is claimed"
_out="$(_run_hook 3 "${_work}/none.txt")"
t_assert_fails test -e "${_ARGV}"
t_assert_fails grep -q -e 'mutation gate' <<<"${_out}"

# Every remaining abort path. A hook that stops refusing is a hook that ships
# what it was built to stop, and each of these was reachable with the suite green.
_abort_rig() {  # $1 = which gate fails; prints the hook's output, then rc=<n>
  printf '#!/usr/bin/env bash\nexit %s\n' "$([ "$1" = preflight ] && echo 1 || echo 0)" \
    > "${_root}/linux/scripts/preflight.sh"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s/bin/shellcheck"\n' "${_work}" \
    > "${_root}/linux/scripts/lint-shell.sh"
  printf '#!/usr/bin/env bash\nexit %s\n' "$([ "$1" = shellcheck ] && echo 1 || echo 0)" \
    > "${_work}/bin/shellcheck"
  chmod +x "${_work}/bin/shellcheck"
  printf 'import sys; sys.exit(%s)\n' "$([ "$1" = ratchet ] && echo 1 || echo 0)" \
    > "${_root}/linux/scripts/verify_shellcheck_warnings.py"
  printf 'import sys; sys.exit(%s)\n' "$([ "$1" = docdupes ] && echo 1 || echo 0)" \
    > "${_root}/docs/scripts/verify_doc_dupes.py"
  local _o _rc
  _o="$(_run_hook 0 "${_work}/abort-staged.txt" 0)"; _rc=$?
  printf '%s\nrc=%s\n' "${_o}" "${_rc}"
}
printf 'linux/scripts/subject.sh\ndocs/page.md\n' > "${_work}/abort-staged.txt"

t_case "a failing fast preflight gate aborts the commit"
_out="$(_abort_rig preflight)"
t_assert_contains "${_out}" "pre-commit: FAILED" "the developer must be told which tier refused"
t_assert_contains "${_out}" "rc=1" "and the commit must not proceed"

t_case "a shellcheck error on a staged file aborts the commit"
_out="$(_abort_rig shellcheck)"
t_assert_contains "${_out}" "shellcheck FAILED on staged files"
t_assert_contains "${_out}" "rc=1"

t_case "a warning-ratchet regression on a staged file aborts the commit"
_out="$(_abort_rig ratchet)"
t_assert_contains "${_out}" "shellcheck warning ratchet FAILED"
t_assert_contains "${_out}" "rc=1"

t_case "a doc-duplication failure on a staged page aborts the commit"
_out="$(_abort_rig docdupes)"
t_assert_contains "${_out}" "doc duplication FAILED"
t_assert_contains "${_out}" "rc=1"

t_case "every gate green: the hook lets the commit through"
_out="$(_abort_rig none)"
t_assert_contains "${_out}" "rc=0" "the rig itself must be able to pass, or the three cases above prove nothing"

t_case "a surviving mutation aborts the commit, it does not just print"
t_assert_fails _run_hook 3 "${_work}/both.txt" 1
t_assert_contains "$(_run_hook 3 "${_work}/both.txt" 1)" "a recorded mutation SURVIVED"

t_summary
