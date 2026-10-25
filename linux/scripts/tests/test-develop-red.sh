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
  local out="${_work}/$1.json"
  "${PY}" - "$1" "${out}" <<'PY'
import json
import sys

scenario, out = sys.argv[1], sys.argv[2]
O, R = "Kataglyphis", "/repos/Kataglyphis"
answers = {}
def run(i, conclusion, updated, event="push"):
    return {"id": i, "workflow_id": 7, "name": "Lane", "path": ".github/workflows/lane.yml",
            "event": event, "conclusion": conclusion, "updated_at": updated,
            "html_url": f"https://github.com/{O}/Fam/actions/runs/{i}", "head_sha": f"{i:040d}"}
def jobs(i, *pages):
    total = sum(len(p) for p in pages)
    for n, page in enumerate(pages, 1):
        answers[f"{R}/Fam/actions/runs/{i}/jobs?filter=latest&per_page=100&page={n}"] = {
            "total_count": total, "jobs": [{"name": k, "conclusion": v} for k, v in page]}
def issue(number, state, seen, red):
    mark = {"repo": "Fam", "workflow_id": 7, "seen": seen, "red": red}
    return {"number": number, "state": state, "body": "text\n\n<!-- develop-red " + json.dumps(mark) + " -->"}
def ref(i):
    return {"run": i, "url": f"https://github.com/{O}/Fam/actions/runs/{i}", "sha": f"{0:08d}"}
repos = [{"name": "Fam", "fork": False, "archived": False, "default_branch": "develop"},
         {"name": "Forked", "fork": True, "archived": False, "default_branch": "develop"},
         {"name": "Old", "fork": False, "archived": True, "default_branch": "develop"},
         {"name": "Mainline", "fork": False, "archived": False, "default_branch": "main"}]
runs, issues = [], []
if scenario == "red-opens":
    runs = [run(12, "failure", "2026-10-20T11:00:00Z"), run(11, "success", "2026-10-20T10:00:00Z")]
    jobs(12, [("build", "failure")], [("lint", "success")])
    jobs(11, [("build", "success"), ("lint", "success")])
elif scenario == "green-quiet":
    runs = [run(12, "success", "2026-10-20T11:00:00Z")]
elif scenario == "ignored-events":
    issues = [issue(5, "open", "2026-10-20T10:00:00Z", {"build": ref(11)})]
    runs = [run(14, "cancelled", "2026-10-20T11:30:00Z"), run(13, "failure", "2026-10-20T11:20:00Z", "pull_request"),
            run(12, "skipped", "2026-10-20T11:10:00Z"), run(11, "failure", "2026-10-20T10:00:00Z")]
    jobs(14, [("build", "success"), ("deploy", "cancelled")])
    jobs(12, [("build", "skipped")])
elif scenario == "umbrella-masked":
    runs = [run(12, "success", "2026-10-20T11:00:00Z"), run(11, "failure", "2026-10-20T10:00:00Z")]
    jobs(12, [("windows / build", "success"), ("web / build", "skipped")])
    jobs(11, [("windows / build", "skipped"), ("web / build", "failure")])
elif scenario == "open-closes":
    issues = [issue(5, "open", "2026-10-20T10:00:00Z", {"build": ref(11)})]
    runs = [run(12, "success", "2026-10-20T11:00:00Z"), run(11, "failure", "2026-10-20T10:00:00Z")]
    jobs(12, [("build", "success")])
elif scenario == "other-lane-green":
    issues = [issue(5, "open", "2026-10-20T10:00:00Z", {"web / build": ref(11)})]
    runs = [run(12, "success", "2026-10-20T11:00:00Z"), run(11, "failure", "2026-10-20T10:00:00Z")]
    jobs(12, [("windows / build", "success"), ("web / build", "skipped")])
elif scenario == "older-rerun":
    issues = [issue(5, "open", "2026-10-20T10:00:00Z", {"build": ref(12)})]
    runs = [run(12, "failure", "2026-10-20T10:00:00Z"), run(11, "success", "2026-10-20T11:00:00Z")]
    jobs(11, [("build", "success")])
elif scenario == "startup-failure":
    runs = [run(12, "startup_failure", "2026-10-20T11:00:00Z")]
    jobs(12, [])
elif scenario == "closed-floor":
    issues = [issue(5, "closed", "2026-10-20T11:00:00Z", {})]
    runs = [run(12, "failure", "2026-10-20T11:00:00Z")]
elif scenario == "old-red-newest":
    runs = [run(12, "failure", "2026-10-01T11:00:00Z")]
    jobs(12, [("build", "failure")])
answers[f"/users/{O}/repos?type=owner&per_page=100"] = repos
answers[f"{R}/ANTfrastructure/issues?labels=develop-red&state=all&sort=created&direction=desc&per_page=100"] = issues
answers[f"{R}/Fam/actions/runs?branch=develop&status=completed&per_page=100"] = {"workflow_runs": runs}
with open(out, "w", encoding="utf-8") as handle:
    json.dump(answers, handle)
PY
  printf '%s' "${out}"
}

_watch() { "${PY}" "${SCRIPT}" --replay "$(_replay "$1")" --now "${NOW}" 2>&1 | grep -v '^watched: '; }

t_case "every run says what it read: only the family repository Fam"
t_assert_eq "watched: 1 workflow(s) in 1 repositories: Fam" \
  "$("${PY}" "${SCRIPT}" --replay "$(_replay green-quiet)" --now "${NOW}" 2>&1)"

t_case "a red newest run opens one issue naming only its red job"
out="$(_watch red-opens)"
t_assert_contains "${out}" "opened: develop is red: Fam · Lane"
t_assert_contains "${out}" '`build`: last failed in [run 12]'
case "${out}" in *'`lint`'*) t_assert_eq "" "lint" "a green job is not listed" ;; *) t_assert_ok true ;; esac
t_assert_contains "${out}" '"labels": ["develop-red"]'

t_case "a green develop writes nothing, and forks, archived and non-develop repos are never read"
t_assert_eq "" "$(_watch green-quiet)" "nothing to say"

t_case "cancelled, skipped and pull-request runs neither close nor touch an open issue"
t_assert_eq "" "$(_watch ignored-events)" "only decisive develop runs count"

t_case "a later run of another lane does not hide an earlier red one"
out="$(_watch umbrella-masked)"
t_assert_contains "${out}" '`web / build`: last failed in [run 11]'
case "${out}" in *'`windows / build`'*) t_assert_eq "" "windows" "a green lane is not listed" ;; *) t_assert_ok true ;; esac

t_case "an open issue closes once its red job passed"
out="$(_watch open-closes)"
t_assert_contains "${out}" "POST /repos/Kataglyphis/ANTfrastructure/issues/5/comments"
t_assert_contains "${out}" '"state": "closed"'
t_assert_contains "${out}" "closed: develop is red: Fam · Lane"

t_case "a green run that skipped the red job keeps the issue open"
out="$(_watch other-lane-green)"
t_assert_contains "${out}" "updated: develop is red: Fam · Lane"
case "${out}" in *closed*) t_assert_eq "" "closed" "the web job never ran again" ;; *) t_assert_ok true ;; esac

t_case "a re-run of an older commit never overrides a newer red"
out="$(_watch older-rerun)"
case "${out}" in *closed*) t_assert_eq "" "closed" "run 12 is newer than run 11" ;; *) t_assert_ok true ;; esac
t_assert_contains "${out}" "updated: develop is red: Fam · Lane"

t_case "a startup failure has no jobs and still opens an issue"
out="$(_watch startup-failure)"
t_assert_contains "${out}" '`(the run itself)`: last failed in [run 12]'

t_case "a closed issue marks the runs it already covered"
t_assert_eq "" "$(_watch closed-floor)" "run 12 finished before the issue closed"

t_case "the newest run counts however old it is"
t_assert_contains "$(_watch old-red-newest)" "opened: develop is red: Fam · Lane"

t_summary
