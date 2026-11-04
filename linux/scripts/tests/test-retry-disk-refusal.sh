#!/usr/bin/env bash
# retry-disk-refusal.sh over a stubbed gh; not covered: GitHub's own re-run and workflow_run behavior, which disk-refusal-selftest.yml proves on a real run.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/test-workspace-fixture.sh
source "${TESTS_DIR}/test-workspace-fixture.sh"
declare _work
t_fixture_workspace_init _work || exit 1
RETRY="${TESTS_DIR}/../../../.github/actions/retry-disk-refusal/retry-disk-refusal.sh"
mkdir -p "${_work}/bin"
# Each annotation answer is <job>.titles; the jobs answer honours the fixture's --jq by holding only failed jobs.
cat > "${_work}/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG}"
case "$*" in
  *"-X POST"*) exit "${POST_RC:-0}" ;;
  *"/attempts/"*) cat "${FIX}/failed"; exit "${JOBS_RC:-0}" ;;
  *"/check-runs/"*) all="$*"; j="${all#*check-runs/}"; j="${j%%/*}"; cat "${FIX}/${j}.titles" 2>/dev/null; exit 0 ;;
esac
exit 9
STUB
chmod +x "${_work}/bin/gh"
declare out rc
_retry() {
  : > "${_work}/log"
  out="$(PATH="${_work}/bin:${PATH}" GH_LOG="${_work}/log" FIX="${_work}" REPO=o/r RUN_ID=7 RUN_ATTEMPT="${1}" MAX_ATTEMPTS=4 JOBS_RC="${JOBS_RC:-0}" POST_RC="${POST_RC:-0}" bash "${RETRY}" 2>&1)"
  rc=$?
}
# <failed-jobs> <job>=<title>...: what the run's attempt answers.
_plant() {
  local pair
  printf '%b' "$1" > "${_work}/failed"
  shift
  for pair in "$@"; do printf '%s\n' "${pair#*=}" > "${_work}/${pair%%=*}.titles"; done
}
_posts() { grep -c -F -e '-X POST' "${_work}/log" || true; }

t_case "a refused job re-runs through the one-job endpoint"
_plant '11 linux / x64\n' 11=runner-disk-refusal
_retry 1
t_assert_eq "0" "${rc}"
t_assert_contains "$(cat "${_work}/log")" "-X POST repos/o/r/actions/jobs/11/rerun"
t_assert_no_grep "${_work}/log" 'rerun-failed-jobs'
t_assert_contains "${out}" "re-running job linux / x64"

t_case "a genuine failure beside it is left alone"
_plant '10 tests\n11 linux / x64\n12 docs\n' '10=pytest failed' 12=runner-disk-refusal
_retry 1
t_assert_eq "1" "$(_posts)"
t_assert_contains "$(cat "${_work}/log")" "actions/jobs/11/rerun"
t_assert_no_grep "${_work}/log" 'actions/jobs/10/rerun'

t_case "with no refusal nothing re-runs, also for a title that only mentions it"
_plant '10 tests\n' '10=not runner-disk-refusal'
_retry 1
t_assert_eq "0" "${rc}"
t_assert_eq "0" "$(_posts)"
t_assert_contains "${out}" "nothing to re-run"
: > "${_work}/failed"
_retry 1
t_assert_eq "0" "$(_posts)"

t_case "the last attempt stays red, and says so"
_plant '11 linux / x64\n'
_retry 4
t_assert_eq "0" "$(_posts)"
t_assert_contains "${out}" "::warning::run 7 stays red"
_retry 3
t_assert_eq "1" "$(_posts)"

t_case "an API failure fails the retry job instead of looking like nothing to do"
JOBS_RC=5 _retry 1
t_assert_eq "5" "${rc}"
POST_RC=6 _retry 1
t_assert_eq "6" "${rc}"

t_summary
