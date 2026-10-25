#!/usr/bin/env bash
# Checks the lane's caller scope and report artifact; it does not run GitHub Actions.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/workflow-lane-fixture.sh"
workflow_lane_fixture_init .github/workflows/python-static.yml static static "${PREFLIGHT_PYTHON:-python3}" || exit 1

_contract() {
  workflow_require_queries \
    'set(V.value(lane,"on")) == {"workflow_call", "workflow_dispatch"} and V.value(V.value(lane,"permissions"),"contents") == "read" and len(V.value(lane,"permissions")) == 1' \
    'all(V.value(V.value(inputs,k),"default") == v for k,v in {"path":".","strict":"false","hub-checkout":"false","runner":"ubuntu-26.04"}.items())' \
    'V.value(V.value(job,"env"),"STATIC_PATH") == "${{ inputs.path || '\''.'\'' }}" and V.value(V.value(job,"env"),"STATIC_STRICT") == "${{ inputs.strict }}" and V.value(V.value(job,"env"),"STATIC_HUB_CHECKOUT") == "${{ inputs.hub-checkout }}"' \
    'len([s for s in steps if re.fullmatch(r"actions/checkout@[0-9a-f]{40}",V.value(s,"uses") or "")]) == 2 and all(V.value(V.value(s,"with"),"persist-credentials") == "false" for s in steps if re.fullmatch(r"actions/checkout@[0-9a-f]{40}",V.value(s,"uses") or ""))' \
    'any(re.fullmatch(r"astral-sh/setup-uv@[0-9a-f]{40}",V.value(s,"uses") or "") for s in steps)' \
    '"--root \"${GITHUB_WORKSPACE}\"" in run_blocks("static") and "--path \"${STATIC_PATH}\" \"${mode}\"" in run_blocks("static") and "${hub}/linux/scripts/python-static.sh" in run_blocks("static")' \
    '"mode=--report-only" in run_blocks("static") and "${STATIC_STRICT}" in run_blocks("static") and "mode=--strict" in run_blocks("static")' \
    'any(V.value(s,"name") == "Upload Python static reports" and V.value(s,"if") == "always()" and re.fullmatch(r"actions/upload-artifact@[0-9a-f]{40}",V.value(s,"uses") or "") and V.value(V.value(s,"with"),"path") == "logs/code-quality/python-static/*.txt" and V.value(V.value(s,"with"),"if-no-files-found") == "error" for s in steps)'
}

_mutated_contract() { LANE="$1" _contract; }

t_case "the reusable lane binds caller scope, strict mode and the ignored report artifact"
t_assert_ok _contract

mkdir -p "${ROOT}/logs/code-quality" || exit 1
_work="$(mktemp -d "${ROOT}/logs/code-quality/python-static-workflow-test.XXXXXX")" || exit 1
trap 'rm -rf -- "${_work}"' EXIT

t_case "the contract catches a scanner aimed at the tooling checkout"
_bad="${_work}/tool-root.yml"
sed 's/--root "${GITHUB_WORKSPACE}"/--root "."/' "${LANE}" > "${_bad}"
t_assert_fails _mutated_contract "${_bad}"

t_case "the contract catches findings forced strict by default"
_bad="${_work}/strict-default.yml"
sed 's/mode=--report-only/mode=--strict/' "${LANE}" > "${_bad}"
t_assert_fails _mutated_contract "${_bad}"

t_case "the contract catches an artifact lost on failed scans"
_bad="${_work}/success-only.yml"
sed 's/if: always()/if: success()/g' "${LANE}" > "${_bad}"
t_assert_fails _mutated_contract "${_bad}"

t_summary
