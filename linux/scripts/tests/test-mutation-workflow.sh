#!/usr/bin/env bash
# This suite grades workflow wiring and fixture validation; GitHub runner execution remains a separate check.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/workflow-lane-fixture.sh
source "${TESTS_DIR}/workflow-lane-fixture.sh"
workflow_lane_fixture_init .github/workflows/mutation-gates.yml mutations mutations python3 || exit 1
VALIDATOR="${ROOT}/docs/scripts/validate_consumer_mutations.py"

_MUTATION_WORKFLOW_QUERIES=(
  'set(V.value(lane,"on")) == {"workflow_call"} and V.value(V.value(lane,"permissions"),"contents") == "read" and len(V.value(lane,"permissions")) == 1'
  'V.value(V.value(inputs,"manifest"),"required") == "true" and V.value(V.value(inputs,"manifest"),"type") == "string" and V.value(V.value(inputs,"hub-checkout"),"default") == "false"'
  'V.value(V.value(inputs,"runner"),"default") == "ubuntu-26.04" and V.value(V.value(inputs,"submodules"),"default") == "recursive"'
  'len([s for s in steps if re.fullmatch(r"actions/checkout@[0-9a-f]{40}",V.value(s,"uses") or "")]) == 2 and all(V.value(V.value(s,"with"),"persist-credentials") == "false" for s in steps if re.fullmatch(r"actions/checkout@[0-9a-f]{40}",V.value(s,"uses") or ""))'
  'any(V.value(s,"name") == "Get ANTfrastructure tooling without a submodule" and V.value(s,"if") == "${{ inputs.hub-checkout }}" for s in steps)'
  'any(V.value(s,"name") == "Upload mutation results" and V.value(s,"if") == "always()" and V.value(V.value(s,"with"),"if-no-files-found") == "error" and re.fullmatch(r"actions/upload-artifact@[0-9a-f]{40}",V.value(s,"uses") or "") for s in steps)'
  'raw.count("validate_consumer_mutations.py") == 1'
  'all(needle in run_blocks("mutations") for needle in ("--root \"${GITHUB_WORKSPACE}\" --manifest \"${MUTATION_MANIFEST}\"", "--root \"${GITHUB_WORKSPACE}\" --manifest \"${GITHUB_WORKSPACE}/${MUTATION_MANIFEST}\"", "set -euo pipefail", "| tee logs/code-quality/mutations/report.txt", "git check-ignore -q --no-index -- logs/code-quality/mutations/report.txt"))'
  '"--setup-script \"${MUTATION_SETUP_SCRIPT}\"" in run_blocks("mutations") and not any(V.value(s,"name") == "Install caller test dependencies" for s in steps)'
)

_workflow_contract() { workflow_require_queries "${_MUTATION_WORKFLOW_QUERIES[@]}"; }

_mutated_workflow() { LANE="$1" _workflow_contract; }

_validator_contract() {
  local script="$1"
  python3 "${script}" --root "${_repo}" --manifest quality/mutations.json >/dev/null 2>&1 || return 1
  python3 "${script}" --root "${_repo}" --manifest quality/empty.json >/dev/null 2>&1 && return 1
  python3 "${script}" --root "${_repo}" --manifest quality/untracked.json >/dev/null 2>&1 && return 1
  python3 "${script}" --root "${_repo}" --manifest quality/escape.json >/dev/null 2>&1 && return 1
  python3 "${script}" --root "${_repo}" --manifest quality/absolute.json >/dev/null 2>&1 && return 1
  return 0
}

t_case "reusable mutation lane keeps caller scope, a fatal verdict and an ignored report"
t_assert_ok test -f "${LANE}"
t_assert_ok _workflow_contract

mkdir -p "${ROOT}/logs/test-results"
_work="$(mktemp -d "${ROOT}/logs/test-results/mutation-workflow.XXXXXX")" || exit 1
trap 'rm -rf -- "${_work}"' EXIT
_repo="${_work}/caller"
mkdir -p "${_repo}/quality" "${_repo}/scripts"
git -C "${_repo}" init -q
printf '%s\n' '[{"id":"sample.bites","target":"src.py","find":"x","replace":"y","test":"true","why":"fixture"}]' > "${_repo}/quality/mutations.json"
printf '%s\n' '[{"id":"sample.escape","target":"../outside.py","find":"x","replace":"y","test":"true","why":"fixture"}]' > "${_repo}/quality/escape.json"
printf '%s\n' '[{"id":"sample.absolute","target":"/tmp/outside.py","find":"x","replace":"y","test":"true","why":"fixture"}]' > "${_repo}/quality/absolute.json"
printf '%s\n' '[]' > "${_repo}/quality/empty.json"
printf '%s\n' '{invalid' > "${_repo}/quality/malformed.json"
printf '%s\n' 'exit 0' > "${_repo}/scripts/setup.sh"
t_git_commit "${_repo}"

t_case "a tracked nonempty caller manifest and setup script select a real recipe"
t_assert_ok python3 "${VALIDATOR}" --root "${_repo}" --manifest quality/mutations.json --setup-script scripts/setup.sh
t_assert_contains "$(python3 "${VALIDATOR}" --root "${_repo}" --manifest quality/mutations.json --shard 0/1)" '1 mutation recipe(s) selected'

t_case "empty, malformed, untracked and escaped manifests cannot pass"
t_assert_rc 2 python3 "${VALIDATOR}" --root "${_repo}" --manifest quality/empty.json
t_assert_rc 2 python3 "${VALIDATOR}" --root "${_repo}" --manifest quality/malformed.json
cp "${_repo}/quality/mutations.json" "${_repo}/quality/untracked.json"
t_assert_rc 2 python3 "${VALIDATOR}" --root "${_repo}" --manifest quality/untracked.json
t_assert_rc 2 python3 "${VALIDATOR}" --root "${_repo}" --manifest quality/escape.json
t_assert_rc 2 python3 "${VALIDATOR}" --root "${_repo}" --manifest quality/absolute.json
t_assert_rc 2 python3 "${VALIDATOR}" --root "${_repo}" --manifest ../quality/mutations.json
t_assert_rc 2 python3 "${VALIDATOR}" --root "${_repo}/quality" --manifest mutations.json

t_case "an empty shard or untracked setup script is fatal"
t_assert_rc 2 python3 "${VALIDATOR}" --root "${_repo}" --manifest quality/mutations.json --shard 1/2
printf '%s\n' 'exit 0' > "${_repo}/scripts/untracked.sh"
t_assert_rc 2 python3 "${VALIDATOR}" --root "${_repo}" --manifest quality/mutations.json --setup-script scripts/untracked.sh

t_case "an empty-manifest or untracked-manifest mutant breaks the validator contract"
t_assert_ok _validator_contract "${VALIDATOR}"
mkdir -p "${_work}/mutant"
cp "${ROOT}/docs/scripts/verify_mutations.py" "${_work}/mutant/verify_mutations.py"
sed 's/if not selected:/if False:/' "${VALIDATOR}" > "${_work}/mutant/empty.py"
t_assert_fails _validator_contract "${_work}/mutant/empty.py"
sed 's/if proc.returncode != 0:/if False:/' "${VALIDATOR}" > "${_work}/mutant/untracked.py"
t_assert_fails _validator_contract "${_work}/mutant/untracked.py"
cp "${VALIDATOR}" "${_work}/mutant/target.py"
sed '/relative_file_path(m\["target"\],/d' "${ROOT}/docs/scripts/verify_mutations.py" > "${_work}/mutant/verify_mutations.py"
t_assert_fails _validator_contract "${_work}/mutant/target.py"

t_case "removing caller scope, validator or artifact failure policy breaks the contract"
_bad="${_work}/wrong-root.yml"
sed 's/--root "${GITHUB_WORKSPACE}"/--root "${hub}"/g' "${LANE}" > "${_bad}"
t_assert_fails _mutated_workflow "${_bad}"
_bad="${_work}/no-validator.yml"
sed 's/validate_consumer_mutations.py/removed_validator.py/' "${LANE}" > "${_bad}"
t_assert_fails _mutated_workflow "${_bad}"
_bad="${_work}/setup-outside-mirror.yml"
sed 's/--setup-script "${MUTATION_SETUP_SCRIPT}"/--setup-removed "${MUTATION_SETUP_SCRIPT}"/' "${LANE}" > "${_bad}"
t_assert_fails _mutated_workflow "${_bad}"
_bad="${_work}/artifact-warn.yml"
sed 's/if-no-files-found: error/if-no-files-found: warn/' "${LANE}" > "${_bad}"
t_assert_fails _mutated_workflow "${_bad}"

t_summary
