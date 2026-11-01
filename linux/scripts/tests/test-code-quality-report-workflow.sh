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
    'run_blocks("report").count("--root") == 5 and run_blocks("report").count("${GITHUB_WORKSPACE}") == 5' \
    'run_blocks("report").count("--report-only") == 4' \
    'run_blocks("report").count("python3 \"${hub}/docs/scripts/verify_hub_reuse.py\"") == 1' \
    '"--hub \"${hub}\"" in run_blocks("report")' \
    '"github.event.repository.fork" in str(lane)' \
    '"hub-reuse.txt" in run_blocks("report")' \
    '"logs/code-quality/measurements" in run_blocks("report")' \
    '"set -euo pipefail" in run_blocks("report")' \
    'any(V.value(s,"name") == "Upload measurements" and V.value(s,"if") == "always()" and V.value(V.value(s,"with"),"path") == "logs/code-quality/measurements/" and V.value(V.value(s,"with"),"if-no-files-found") == "error" for s in steps)'
}

_quality_contract() {
  workflow_require_queries \
    'V.value(V.value(inputs,"quality-report"),"type") == "boolean" and str(V.value(V.value(inputs,"quality-report"),"default")).lower() == "false"' \
    'all(V.value(s,"if") == "${{ inputs.quality-report }}" for s in steps if V.value(s,"name") in ("Install uv for quality-report", "Grade the checkout with quality-report"))' \
    '"--compare previous-develop" in run_blocks("report") and "linux/scripts/quality-report.sh" in run_blocks("report")' \
    '"git -C \"${hub}\" submodule update --init --depth 1 -- third_party/DocumANTation || exit 1" in run_blocks("report") and run_blocks("report").index("submodule update") < run_blocks("report").index("quality-report.sh")' \
    'V.value(V.value(next(s for s in steps if V.value(s,"name") == "Grade the checkout with quality-report"),"env"),"GH_TOKEN") == "${{ github.token }}"' \
    'any(V.value(s,"if") == "${{ always() && inputs.quality-report }}" and V.value(V.value(s,"with"),"name") == "code-quality-measurements" and V.value(V.value(s,"with"),"retention-days") == "90" and V.value(V.value(s,"with"),"if-no-files-found") == "error" for s in steps)' \
    're.search(r"name: code-quality-measurements\n +path: \|\n +logs/code-quality/measurements.json\n +logs/code-quality/queue.md\n", raw) is not None'
}

_changed_contract() { LANE="$1" _report_contract; }

_step_script() {
  awk -v step="      - name: $1" '
    $0 == step { selected = 1; next }
    selected && /^        run: \|$/ { running = 1; next }
    running && /^      - name: / { exit }
    running { sub(/^          /, ""); print; commands++ }
    END { if (!commands) exit 1 }
  ' "${LANE}"
}
_changed_quality() { LANE="$1" _quality_contract; }

t_case "all four rooted scanners produce ignored, uploaded measurements"
t_assert_ok _report_contract

mkdir -p "${ROOT}/logs/code-quality" || exit 1
work="$(mktemp -d "${ROOT}/logs/code-quality/report-workflow-test.XXXXXX")" || exit 1
trap 'rm -rf -- "${work}"' EXIT

t_case "quality-report is opt-in, compares with develop and keeps its artifact for 90 days"
t_assert_ok _quality_contract

t_case "quality-report switched on by default is rejected"
awk '/^      quality-report:$/ { q = 1 } q && /default: false/ { sub(/false/, "true"); q = 0 } { print }' \
  "${LANE}" > "${work}/default-on.yml"
t_assert_fails _changed_quality "${work}/default-on.yml"

t_case "quality-report without the pinned docs theme is rejected"
sed '/submodule update --init --depth 1 -- third_party\/DocumANTation/d' "${LANE}" > "${work}/no-theme.yml"
t_assert_fails _changed_quality "${work}/no-theme.yml"

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
_step_script "Measure tracked code" > "${work}/measure.sh" || exit 1
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

t_case "only an incomplete or crashed quality-report fails the job"
_step_script "Grade the checkout with quality-report" > "${work}/grade.sh" || exit 1
mkdir -p "${hub}/linux/scripts" "${work}/bin" || exit 1
printf '#!/usr/bin/env bash\n[ "$*" = "-C third_party/ANTfrastructure submodule update --init --depth 1 -- third_party/DocumANTation" ] && [ "${GIT_STUB_FAIL:-0}" = 0 ]\n' \
  > "${work}/bin/git" && chmod +x "${work}/bin/git" || exit 1
_grade() {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\nexit %s\n' "$1" "$2" \
    > "${hub}/linux/scripts/quality-report.sh"
  (cd "${work}" && PATH="${work}/bin:${PATH}" GITHUB_REPOSITORY=Kataglyphis/Consumer REPORT_HUB_CHECKOUT=false \
    GITHUB_WORKSPACE="${work}" GITHUB_STEP_SUMMARY="${work}/summary.md" bash "${work}/grade.sh")
}
t_assert_ok _grade 'quality-report: verdict=ok regressed=0 improved=0 metrics=3' 0
t_assert_ok _grade 'quality-report: verdict=regressed regressed=1 improved=0 metrics=3' 1
t_assert_fails _grade 'Traceback (most recent call last):' 1
t_assert_fails _grade 'quality-report: verdict=incomplete regressed=0 improved=0 metrics=3' 2
GIT_STUB_FAIL=1 t_assert_fails _grade 'quality-report: verdict=ok regressed=0 improved=0 metrics=3' 0

t_summary
