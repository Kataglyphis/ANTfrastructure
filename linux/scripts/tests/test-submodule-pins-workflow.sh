#!/usr/bin/env bash
# Static wiring cannot prove a remote submodule fetch; the Windows Pester lane executes that check.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/workflow-lane-fixture.sh
source "${TESTS_DIR}/workflow-lane-fixture.sh"
workflow_lane_fixture_init .github/workflows/submodule-pins.yml pins pins "${PREFLIGHT_PYTHON:-python3}" || exit 1

_pin_contract() {
  workflow_require_queries \
    'V.value(V.value(inputs,"hub-checkout"),"type") == "boolean" and V.value(V.value(inputs,"hub-checkout"),"default") == "false"' \
    'any(V.value(s,"name") == "Get ANTfrastructure tooling without a submodule" and V.value(s,"if") == "${{ inputs.hub-checkout }}" and V.value(V.value(s,"with"),"repository") == "Kataglyphis/ANTfrastructure" and V.value(V.value(s,"with"),"path") == "antfrastructure-tools" and V.value(V.value(s,"with"),"persist-credentials") == "false" for s in steps)' \
    'any(V.value(s,"name") == "Submodule pins sit at their recorded, restorable commits" and "inputs.hub-checkout &&" in V.value(V.value(s,"with"),"path") and V.value(V.value(s,"with"),"path").count("shared/windows/tests/Submodule.Pins.Tests.ps1") == 2 and "inputs.suite-path ||" in V.value(V.value(s,"with"),"path") for s in steps)' \
    'V.value(V.value(job,"env"),"ANTFRASTRUCTURE_PIN_CHECK_REPO_ROOT") == "${{ github.workspace }}"'
}

_mutated_pin_contract() { LANE="$1" _pin_contract; }

t_case "a caller without a hub gitlink checks out the canonical pin suite"
t_assert_ok _pin_contract

mkdir -p "${ROOT}/logs/code-quality"
work="$(mktemp -d "${ROOT}/logs/code-quality/submodule-pins-workflow.XXXXXX")" || exit 1
trap 'rm -rf -- "${work}"' EXIT

t_case "removing the conditional checkout or its canonical suite path breaks the contract"
sed 's/if: ${{ inputs.hub-checkout }}/if: false/' "${LANE}" > "${work}/disabled.yml"
t_assert_fails _mutated_pin_contract "${work}/disabled.yml"
sed 's@antfrastructure-tools/shared/windows/tests/Submodule.Pins.Tests.ps1@missing/Pin.Tests.ps1@' \
  "${LANE}" > "${work}/wrong-suite.yml"
t_assert_fails _mutated_pin_contract "${work}/wrong-suite.yml"

t_case "a tool checkout that leaves credentials behind breaks the contract"
sed '/path: antfrastructure-tools/{n;s/persist-credentials: false/persist-credentials: true/;}' \
  "${LANE}" > "${work}/credentials.yml"
t_assert_fails _mutated_pin_contract "${work}/credentials.yml"

t_summary
