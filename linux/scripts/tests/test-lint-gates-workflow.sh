#!/usr/bin/env bash
# lint-gates.yml's inputs, flags and report upload as parsed YAML; it does not run GitHub Actions.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=workflow-lane-fixture.sh
source "${TESTS_DIR}/workflow-lane-fixture.sh"
workflow_lane_fixture_init .github/workflows/lint-gates.yml lint-gates lint-gates python3 || exit 1

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

t_case "the reusable workflow measures duplication by default and exposes a separate strict switch"
workflow_assert_input_fields code-dupes type 'boolean' default 'false'
workflow_assert_input_fields code-dupes-report type 'boolean' default 'true'
workflow_assert_input_fields allow-empty-shell type 'boolean' default 'false'
workflow_assert_input_fields agents-drift type 'boolean' default 'false'
workflow_assert_input_fields workflow-conventions type 'string' default ''
t_assert_eq "\${{ inputs.workflow-conventions }}" "$(_q "V.value(V.value(job, 'env'), 'WORKFLOW_CONVENTIONS_GATE')")" \
  "a caller's armed conventions must reach the gate's environment"
t_assert_contains "$(_q "run_blocks('lint-gates')")" 'args+=(--code-dupes)'
t_assert_contains "$(_q "run_blocks('lint-gates')")" 'args+=(--code-dupes-report)'
t_assert_contains "$(_q "run_blocks('lint-gates')")" 'args+=(--agents-drift)'
t_assert_contains "$(_q "run_blocks('lint-gates')")" 'args+=(--allow-empty-shell)'

t_case "the workflow uploads the caller duplication report even after findings"
workflow_assert_artifact_step 'Save duplication report' 'logs/code-quality/code-dupes.txt' 'inputs.code-dupes-report'
_faulted_workflow="${_work}/lint-gates-no-report.yml"
sed '/- name: Save duplication report/,+6d' "${LANE}" > "${_faulted_workflow}"
t_assert_eq "False" "$(LANE="${_faulted_workflow}" _q "any(V.value(s,'name') == 'Save duplication report' for s in steps)")" \
  "the upload assertion must fail if the step is deleted"

t_summary
