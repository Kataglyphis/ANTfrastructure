#!/usr/bin/env bash
# A fixture executes the measurement step so missing pinned tooling cannot pass CI.
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
    'all(name in run_blocks("report") for name in ("verify_code_dupes.py", "verify_code_size.py", "verify_code_complexity.py", "verify_hub_reuse.py"))' \
    'run_blocks("report").count("--root") == 4 and run_blocks("report").count("${GITHUB_WORKSPACE}") == 4' \
    'run_blocks("report").count("--report-only") == 4' \
    'run_blocks("report").count("python3 \"${hub}/docs/scripts/verify_hub_reuse.py\"") == 1' \
    '"--hub \"${hub}\"" in run_blocks("report")' \
    '"github.event.repository.fork" in str(lane)' \
    '"hub-reuse.txt" in run_blocks("report")' \
    '"logs/code-quality/measurements" in run_blocks("report")' \
    '"set -euo pipefail" in run_blocks("report")' \
    'any(V.value(s,"name") == "Upload measurements" and V.value(s,"if") == "always()" and V.value(V.value(s,"with"),"path") == "logs/code-quality/measurements/" and V.value(V.value(s,"with"),"if-no-files-found") == "error" for s in steps)'
}

_changed_contract() { LANE="$1" _report_contract; }

t_case "all four rooted scanners produce ignored, uploaded measurements"
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

t_case "an owned caller fails when its pinned hub lacks the reuse scanner"
awk '
  /^      - name: Measure tracked code$/ { selected = 1; next }
  selected && /^        run: \|$/ { running = 1; next }
  running && /^      - name: / { exit }
  running { sub(/^          /, ""); print; commands++ }
  END { if (!commands) exit 1 }
' "${LANE}" > "${work}/measure.sh" || exit 1
hub="${work}/third_party/ANTfrastructure"
mkdir -p "${hub}/docs/scripts" "${hub}/linux/scripts" || exit 1
for scanner in "${hub}/docs/scripts/verify_code_dupes.py" \
  "${hub}/linux/scripts/verify_code_size.py" \
  "${hub}/linux/scripts/verify_code_complexity.py" \
  "${hub}/docs/scripts/verify_hub_reuse.py"; do
  printf 'print("measured")\n' > "${scanner}"
done

_run_report() {
  (cd "${work}" && GITHUB_REPOSITORY="$1" REPORT_REPO_FORK="${2:-false}" \
    REPORT_HUB_CHECKOUT=false GITHUB_WORKSPACE="${work}" \
    GITHUB_STEP_SUMMARY="${work}/summary.md" bash "${work}/measure.sh")
}

t_assert_ok _run_report Kataglyphis/Consumer
rm -- "${hub}/docs/scripts/verify_hub_reuse.py"
t_assert_rc 1 _run_report Kataglyphis/Consumer
t_assert_contains "$(cat "${work}/logs/code-quality/measurements/hub-reuse.txt")" \
  'needs a newer ANTfrastructure gitlink'
t_assert_ok _run_report AnotherOrg/Consumer
t_assert_ok _run_report Kataglyphis/Fork true

t_summary
