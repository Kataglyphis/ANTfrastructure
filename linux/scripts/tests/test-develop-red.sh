#!/usr/bin/env bash
# develop_red.py over replayed API answers whose verdict is known in advance; offline, nothing is written.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPT="$(cd "${TESTS_DIR}/.." && pwd)/develop_red.py"
PY="${PREFLIGHT_PYTHON:-python3}"
NOW="2026-10-20T12:00:00Z"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# _replay <scenario>: writes the API answers for one scenario and prints the file's path.
_replay() {
  "${PY}" "${TESTS_DIR}/develop_red_replays.py" "$1" "${_work}/$1.json" || return 1
  printf '%s' "${_work}/$1.json"
}

# _never <output> <needle> <why>: the needle must not appear.
_never() { case "$1" in *"$2"*) t_assert_eq "" "$2" "$3" ;; *) t_assert_ok true ;; esac; }
_watch() { "${PY}" "${SCRIPT}" --replay "$(_replay "$1")" --now "${NOW}" 2>&1 | grep -v '^watched: '; }

t_case "every run says what it read: only the family repository Fam"
t_assert_eq "watched: 1 workflow(s) in 1 repositories: Fam" \
  "$("${PY}" "${SCRIPT}" --replay "$(_replay green-quiet)" --now "${NOW}" 2>&1)"

t_case "a red newest run opens one issue naming only its red job"
out="$(_watch red-opens)"
t_assert_contains "${out}" "opened: develop is red: Fam · Lane"
t_assert_contains "${out}" '`build`: last failed in [run 12]'
_never "${out}" '`lint`' "a green job is not listed"
t_assert_contains "${out}" '"labels": ["develop-red"]'

t_case "a green develop writes nothing, and forks, archived and non-develop repos are never read"
t_assert_eq "" "$(_watch green-quiet)" "nothing to say"

t_case "cancelled, skipped and pull-request runs neither close nor touch an open issue"
t_assert_eq "" "$(_watch ignored-events)" "only decisive develop runs count"

t_case "a later run of another lane does not hide an earlier red one"
out="$(_watch umbrella-masked)"
t_assert_contains "${out}" '`web / build`: last failed in [run 11]'
_never "${out}" '`windows / build`' "a green lane is not listed"

t_case "an open issue closes once its red job passed"
out="$(_watch open-closes)"
t_assert_contains "${out}" "POST /repos/Kataglyphis/ANTfrastructure/issues/5/comments"
t_assert_contains "${out}" '"state": "closed"'
t_assert_contains "${out}" "closed: develop is red: Fam · Lane"

t_case "a green run that skipped the red job keeps the issue open"
out="$(_watch other-lane-green)"
t_assert_contains "${out}" "updated: develop is red: Fam · Lane"
_never "${out}" closed "the web job never ran again"

t_case "a re-run of an older commit never overrides a newer red"
out="$(_watch older-rerun)"
_never "${out}" closed "run 12 is newer than run 11"
t_assert_contains "${out}" "updated: develop is red: Fam · Lane"

t_case "a startup failure has no jobs and still opens an issue"
out="$(_watch startup-failure)"
t_assert_contains "${out}" '`(the run itself)`: last failed in [run 12]'

t_case "a closed issue marks the runs it already covered"
t_assert_eq "" "$(_watch closed-floor)" "run 12 finished before the issue closed"

t_case "the newest run counts however old it is"
t_assert_contains "$(_watch old-red-newest)" "opened: develop is red: Fam · Lane"

t_case "an open issue of a deleted workflow closes with the reason, and opens nothing new"
out="$(_watch workflow-deleted)"
t_assert_contains "${out}" "closed: Fam workflow 7 is deleted"
t_assert_contains "${out}" 'The workflow `.github/workflows/lane.yml` is deleted: it runs no more'
t_assert_contains "${out}" '"state_reason": "not_planned"'
_never "${out}" opened "a deleted workflow never gets a new issue"

t_case "a red run of a disabled workflow opens nothing"
t_assert_eq "" "$(_watch workflow-disabled)" "its jobs can never pass, so an issue could never close"

t_case "an open issue missing from the repo-wide page is read through its workflow's own runs"
t_assert_contains "$(_watch missing-from-page)" "closed: develop is red: Fam · Lane"

t_case "a stale repo-wide page is confirmed against the workflow's own newest run, and opens nothing"
t_assert_eq "" "$(_watch stale-page)" "run 12 is green and newer than the page's run 11"

t_case "a red job absent from two newer green runs is retired and named"
out="$(_watch job-retired)"
t_assert_contains "${out}" "closed: develop is red: Fam · Lane"
t_assert_contains "${out}" 'Retired `A / gate`: absent from the newer green runs 13 and 12.'

t_case "one green run without the job is not yet proof"
out="$(_watch one-green-only)"
_never "${out}" closed "one run can be a partial round"
t_assert_contains "${out}" '`A / gate`: last failed in [run 11]' "the job stays listed until a second green run lacks it"

t_case "a red nested job stays open while newer runs skipped its caller"
out="$(_watch caller-skipped)"
_never "${out}" closed "a skipped caller hides every nested job"
t_assert_contains "${out}" "updated: develop is red: Fam · Lane"

t_case "a red job a newer green run skipped is not absent, and stays open"
out="$(_watch job-skipped)"
_never "${out}" closed "skipped is not gone"

t_case "the recorded marks of hub issues #110 and #111 close under this watcher"
_recorded="${TESTS_DIR}/fixtures/develop-red-recorded.json"
_rec() { "${PY}" "${SCRIPT}" --replay "$1" --now 2026-10-30T15:18:00Z 2>&1; }
out="$(_rec "${_recorded}")"
t_assert_contains "${out}" "closed: BeschleunigerBallett workflow 164515706 is deleted" "#110: Linux_x86.yml was deleted"
t_assert_contains "${out}" "closed: develop is red: BeschleunigerBallett · Windows arm64 · cross build + test" "#111"
t_assert_contains "${out}" 'Retired `Cross build (arm64) / bundle device gate (windows-11-arm)`: absent from the newer green runs 39024767294 and 38562264186.'

t_case "#111's stale page, where run 38156104572 hides the newer green 39024767294, opens nothing"
"${PY}" -c 'import json, sys; a = json.load(open(sys.argv[1])); k = [p for p in a if "/issues?" in p][0]; a[k] = []; json.dump(a, open(sys.argv[2], "w"))' \
  "${_recorded}" "${_work}/no-issues.json"
out="$(_rec "${_work}/no-issues.json")"
_never "${out}" opened "the workflow's own newest run is green"

t_case "a job still red in the newest decisive run keeps its issue open"
out="$(_watch still-red)"
_never "${out}" closed "run 13 failed the job again"
t_assert_contains "${out}" '`build`: last failed in [run 13]'

t_case "an issue beyond the first 100 is still found"
t_assert_contains "$(_watch issue-beyond-100)" "POST /repos/Kataglyphis/ANTfrastructure/issues/5/comments"

t_case "a jobs page answering 5xx four times then 200 settles normally"
t_assert_contains "$(_watch jobs-5xx-recovers)" "opened: develop is red: Fam · Lane"

t_case "a jobs page that never recovers fails the run, naming it, after the other repositories settled"
_never="$(_replay jobs-5xx-never)"
out="$("${PY}" "${SCRIPT}" --replay "${_never}" --now "${NOW}" 2>&1)"
t_assert_contains "${out}" "opened: develop is red: Second · Lane"
t_assert_contains "${out}" "failed: Fam: HTTP Error 502"
t_assert_contains "${out}" "FAILED: the API never answered for Fam"
t_assert_rc 1 "${PY}" "${SCRIPT}" --replay "${_never}" --now "${NOW}"

# _flaky <code> <method> <failures>: a Client call against an API that fails <failures> times; prints the outcome and the attempts.
_flaky() {
  "${PY}" - "${SCRIPT}" "$@" <<'PY' 2>/dev/null
import importlib.util
import io
import sys
import urllib.error
from email.message import Message

spec = importlib.util.spec_from_file_location("develop_red", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
code, method, failures = int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
calls = []
def urlopen(req, timeout):
    calls.append(1)
    if len(calls) <= failures:
        raise urllib.error.HTTPError(req.full_url, code, "fail", Message(), None)
    return io.BytesIO(b'{"ok": true}')
mod.urllib.request.urlopen = urlopen
mod.time.sleep = lambda s: None
try:
    mod.Client("", False, None).call(method, "/x", None if method == "GET" else {})
    print(f"ok {len(calls)}")
except urllib.error.HTTPError as e:
    print(f"raised {e.code} {len(calls)}")
PY
}

t_case "a GET retries a 5xx and succeeds"
t_assert_eq "ok 3" "$(_flaky 502 GET 2)"

t_case "a GET outlasts four 5xx answers and gives up after the fifth"
t_assert_eq "ok 5" "$(_flaky 502 GET 4)"
t_assert_eq "raised 502 5" "$(_flaky 502 GET 9)"

t_case "a 4xx and a failed write are never retried"
t_assert_eq "raised 404 1" "$(_flaky 404 GET 1)"
t_assert_eq "raised 502 1" "$(_flaky 502 POST 1)"

t_summary
