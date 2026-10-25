#!/usr/bin/env bash
# Workflow structure cannot prove a Windows runner executes the report step or writes valid JSON.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/workflow-lane-fixture.sh
source "${TESTS_DIR}/workflow-lane-fixture.sh"
workflow_lane_fixture_init .github/workflows/windows-x64.yml lint-and-test lint-and-test "${PREFLIGHT_PYTHON:-python3}" || exit 1

_step_block() {
  awk -v heading="$1" '
    { sub(/\r$/, "") }
    /^      - name: / {
      if (active) exit
      active = ($0 == "      - name: " heading)
    }
    active { print }
  ' "$2"
}

_report_contract() {
  local lane="$1" block upload
  block="$(_step_block 'Enforce PowerShell complexity' "${lane}")"
  [[ "${block}" == *'New-Item -ItemType Directory -Force logs/code-quality/complexity | Out-Null'* ]] || return 1
  [[ "${block}" == *'windows/scripts/Invoke-CodeComplexity.ps1 -Strict -JsonPath logs/code-quality/complexity/windows-full.json'* ]] || return 1
  upload="next(s for s in steps if V.value(s,'name') == 'Save complexity report')"
  LANE="${lane}" workflow_require_queries \
    "len([s for s in steps if V.value(s,'name') == 'Save complexity report']) == 1" \
    "V.value(V.value(${upload},'with'),'path') == 'logs/code-quality/complexity/windows-full.json'" \
    "V.value(V.value(${upload},'with'),'if-no-files-found') == 'error'" \
    "V.value(${upload},'if') == 'always()'" \
    "bool(re.fullmatch(r'actions/upload-artifact@[0-9a-f]{40}', V.value(${upload},'uses') or ''))"
}

t_case "strict Windows complexity writes JSON and uploads the exact report"
t_assert_ok _report_contract "${LANE}"

t_case "the Pester report upload still runs after failures"
pester="next(s for s in steps if V.value(s,'name') == 'Save test and coverage reports')"
t_assert_eq 'logs/windows-tests/' "$(_q "V.value(V.value(${pester},'with'),'path')")"
t_assert_eq error "$(_q "V.value(V.value(${pester},'with'),'if-no-files-found')")"
t_assert_eq 'always()' "$(_q "V.value(${pester},'if')")"

_mutated="$(mktemp)"
trap 'rm -f "${_mutated}"' EXIT
t_case "removing complexity JSON generation breaks the report contract"
sed 's/ -Strict -JsonPath logs\/code-quality\/complexity\/windows-full.json/ -Strict/' "${LANE}" > "${_mutated}"
t_assert_fails _report_contract "${_mutated}"

t_case "an optional complexity artifact breaks the report contract"
sed 's/if-no-files-found: error/if-no-files-found: warn/g' "${LANE}" > "${_mutated}"
t_assert_fails _report_contract "${_mutated}"

t_summary
