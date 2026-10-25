#!/usr/bin/env bash
# The workflow contract is static; GitHub executes the measured scripts in CI.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/workflow-lane-fixture.sh
source "${TESTS_DIR}/workflow-lane-fixture.sh"
PY="${PREFLIGHT_PYTHON:-python3}"
workflow_lane_fixture_init .github/workflows/code-quality-report.yml report report "${PY}" || exit 1

_report_contract() {
  workflow_require_queries \
    'set(V.value(lane,"on")) == {"workflow_call", "workflow_dispatch"}' \
    'V.value(V.value(lane,"permissions"),"contents") == "read"' \
    'all(V.value(V.value(s,"with"),"persist-credentials") == "false" for s in steps if "actions/checkout@" in (V.value(s,"uses") or ""))' \
    'all(name in run_blocks("report") for name in ("verify_code_dupes.py", "verify_code_size.py", "verify_code_complexity.py"))' \
    'run_blocks("report").count("--root") == 3 and run_blocks("report").count("${GITHUB_WORKSPACE}") == 3' \
    'run_blocks("report").count("--report-only") == 3' \
    '"logs/code-quality/measurements" in run_blocks("report")' \
    '"set -euo pipefail" in run_blocks("report")' \
    'any(V.value(s,"name") == "Upload measurements" and V.value(s,"if") == "always()" and V.value(V.value(s,"with"),"path") == "logs/code-quality/measurements/" and V.value(V.value(s,"with"),"if-no-files-found") == "error" for s in steps)'
}

_changed_contract() { LANE="$1" _report_contract; }

t_case "all three rooted scanners produce ignored, uploaded measurements"
t_assert_ok _report_contract

mkdir -p "${ROOT}/logs/code-quality" || exit 1
work="$(mktemp -d "${ROOT}/logs/code-quality/report-workflow-test.XXXXXX")" || exit 1
trap 'rm -rf -- "${work}"' EXIT

t_case "a scanner that silently returns a verdict instead of a report is rejected"
sed '0,/--report-only/s/--report-only/--check/' "${LANE}" > "${work}/no-report.yml"
t_assert_fails _changed_contract "${work}/no-report.yml"

t_case "a scanner aimed at the hub instead of the caller is rejected"
sed '0,/--root "${GITHUB_WORKSPACE}"/s/--root "${GITHUB_WORKSPACE}"/--root ./' \
  "${LANE}" > "${work}/wrong-root.yml"
t_assert_fails _changed_contract "${work}/wrong-root.yml"

t_case "a failed measurement still keeps its artifact"
sed 's/if: always()/if: success()/' "${LANE}" > "${work}/success-only.yml"
t_assert_fails _changed_contract "${work}/success-only.yml"

t_summary
