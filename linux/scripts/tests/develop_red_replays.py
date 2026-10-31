"""Write the replayed API answers of one develop-red scenario: develop_red_replays.py <scenario> <out.json>."""
from __future__ import annotations

import json
import sys
from collections.abc import Callable
from typing import Any

O, R = "Kataglyphis", "/repos/Kataglyphis"
ISSUES = f"{R}/ANTfrastructure/issues?labels=develop-red&state=all&sort=created&direction=desc&per_page=100&page="
FAMILY = [{"name": "Fam", "fork": False, "archived": False, "default_branch": "develop"},
          {"name": "Forked", "fork": True, "archived": False, "default_branch": "develop"},
          {"name": "Old", "fork": False, "archived": True, "default_branch": "develop"},
          {"name": "Mainline", "fork": False, "archived": False, "default_branch": "main"}]


class World:
    """One repository's runs, jobs, workflow record and hub issues, as the watcher would read them."""

    def __init__(self) -> None:
        self.answers: dict[str, Any] = {}
        self.runs: list[dict] = []
        self.wf_runs: list[dict] | None = None
        self.issues: list[dict] = []
        self.pages: dict[int, list[dict]] = {}
        self.state = "active"
        self.repos = list(FAMILY)

    def run(self, i: int, conclusion: str, updated: str, event: str = "push", repo: str = "Fam") -> dict:
        return {"id": i, "workflow_id": 7, "name": "Lane", "path": ".github/workflows/lane.yml",
                "event": event, "conclusion": conclusion, "updated_at": updated,
                "html_url": f"https://github.com/{O}/{repo}/actions/runs/{i}", "head_sha": f"{i:040d}"}

    def jobs(self, i: int, *pages: list[tuple[str, str]], repo: str = "Fam") -> None:
        total = sum(len(p) for p in pages)
        for n, page in enumerate(pages, 1):
            self.answers[f"{R}/{repo}/actions/runs/{i}/jobs?filter=latest&per_page=100&page={n}"] = {
                "total_count": total, "jobs": [{"name": k, "conclusion": v} for k, v in page]}

    def green(self, i: int, updated: str, names: list[str]) -> dict:
        self.jobs(i, [(n, "success") for n in names])
        return self.run(i, "success", updated)

    def write(self, out: str) -> None:
        a = self.answers
        a[f"/users/{O}/repos?type=owner&per_page=100"] = self.repos
        for n, page in (self.pages or {1: self.issues}).items():
            a[f"{ISSUES}{n}"] = page
        a[f"{R}/Fam/actions/runs?branch=develop&status=completed&per_page=100"] = {"workflow_runs": self.runs}
        a[f"{R}/Fam/actions/workflows/7/runs?branch=develop&status=completed&per_page=100"] = {
            "workflow_runs": self.runs if self.wf_runs is None else self.wf_runs}
        a[f"{R}/Fam/actions/workflows/7"] = {"id": 7, "path": ".github/workflows/lane.yml", "state": self.state}
        with open(out, "w", encoding="utf-8") as handle:
            json.dump(a, handle)


def issue(number: int, state: str, seen: str, red: dict) -> dict:
    mark = {"repo": "Fam", "workflow_id": 7, "seen": seen, "red": red}
    return {"number": number, "state": state, "body": "text\n\n<!-- develop-red " + json.dumps(mark) + " -->"}


def ref(i: int) -> dict:
    return {"run": i, "url": f"https://github.com/{O}/Fam/actions/runs/{i}", "sha": f"{0:08d}"}


def open_red(w: World, red: dict, seen: str = "2026-10-20T10:00:00Z") -> None:
    w.issues = [issue(5, "open", seen, red)]


def red_opens(w: World) -> None:
    w.runs = [w.run(12, "failure", "2026-10-20T11:00:00Z"), w.run(11, "success", "2026-10-20T10:00:00Z")]
    w.jobs(12, [("build", "failure")], [("lint", "success")])
    w.jobs(11, [("build", "success"), ("lint", "success")])


def green_quiet(w: World) -> None:
    w.runs = [w.run(12, "success", "2026-10-20T11:00:00Z")]


def ignored_events(w: World) -> None:
    open_red(w, {"build": ref(11)})
    w.runs = [w.run(14, "cancelled", "2026-10-20T11:30:00Z"), w.run(13, "failure", "2026-10-20T11:20:00Z", "pull_request"),
              w.run(12, "skipped", "2026-10-20T11:10:00Z"), w.run(11, "failure", "2026-10-20T10:00:00Z")]
    w.jobs(14, [("build", "success"), ("deploy", "cancelled")])
    w.jobs(12, [("build", "skipped")])


def umbrella_masked(w: World) -> None:
    w.runs = [w.run(12, "success", "2026-10-20T11:00:00Z"), w.run(11, "failure", "2026-10-20T10:00:00Z")]
    w.jobs(12, [("windows / build", "success"), ("web / build", "skipped")])
    w.jobs(11, [("windows / build", "skipped"), ("web / build", "failure")])


def open_closes(w: World) -> None:
    open_red(w, {"build": ref(11)})
    w.runs = [w.run(12, "success", "2026-10-20T11:00:00Z"), w.run(11, "failure", "2026-10-20T10:00:00Z")]
    w.jobs(12, [("build", "success")])


def other_lane_green(w: World) -> None:
    open_red(w, {"web / build": ref(11)})
    w.runs = [w.run(12, "success", "2026-10-20T11:00:00Z"), w.run(11, "failure", "2026-10-20T10:00:00Z")]
    w.jobs(12, [("windows / build", "success"), ("web / build", "skipped")])


def older_rerun(w: World) -> None:
    open_red(w, {"build": ref(12)})
    w.runs = [w.run(12, "failure", "2026-10-20T10:00:00Z"), w.run(11, "success", "2026-10-20T11:00:00Z")]
    w.jobs(11, [("build", "success")])


def startup_failure(w: World) -> None:
    w.runs = [w.run(12, "startup_failure", "2026-10-20T11:00:00Z")]
    w.jobs(12, [])


def closed_floor(w: World) -> None:
    w.issues = [issue(5, "closed", "2026-10-20T11:00:00Z", {})]
    w.runs = [w.run(12, "failure", "2026-10-20T11:00:00Z")]


def old_red_newest(w: World) -> None:
    w.runs = [w.run(12, "failure", "2026-10-01T11:00:00Z")]
    w.jobs(12, [("build", "failure")])


def workflow_deleted(w: World) -> None:
    w.state = "deleted"
    open_red(w, {"build": ref(11)})


def red_today(w: World) -> None:
    w.runs = [w.run(12, "failure", "2026-10-20T11:00:00Z")]
    w.jobs(12, [("build", "failure")])


def workflow_disabled(w: World) -> None:
    w.state = "disabled_manually"
    red_today(w)


def missing_from_page(w: World) -> None:
    open_red(w, {"build": ref(11)})
    w.wf_runs = [w.green(12, "2026-10-20T11:00:00Z", ["build"]), w.run(11, "failure", "2026-10-20T10:00:00Z")]


def stale_page(w: World) -> None:
    w.runs = [w.run(11, "failure", "2026-10-11T18:24:38Z")]
    w.wf_runs = [w.green(12, "2026-10-17T12:28:44Z", ["gate / build"]), w.runs[0]]
    w.jobs(11, [("gate / build", "failure")])


def job_retired(w: World) -> None:
    open_red(w, {"A / gate": ref(11)}, "2026-10-20T09:00:00Z")
    shown = ["A / build", "A / run"]
    w.runs = [w.green(13, "2026-10-20T11:00:00Z", shown), w.green(12, "2026-10-20T10:00:00Z", shown),
              w.run(11, "failure", "2026-10-20T09:00:00Z")]


def one_green_only(w: World) -> None:
    job_retired(w)
    w.runs = w.runs[1:]


def _skipped(w: World, red: str, skipped: str) -> None:
    """OmniAccelerANT run 40529524325's shape: a green on-request run whose lanes were skipped callers."""
    open_red(w, {red: ref(11)}, "2026-10-20T09:00:00Z")
    w.runs = [w.run(13, "success", "2026-10-20T11:00:00Z"), w.run(12, "success", "2026-10-20T10:00:00Z"),
              w.run(11, "failure", "2026-10-20T09:00:00Z")]
    for i in (12, 13):
        w.jobs(i, [("Which lanes", "success"), ("android / build", "success"), (skipped, "skipped")])


def caller_skipped(w: World) -> None:
    _skipped(w, "windows-x64 / build", "windows-x64")


def job_skipped(w: World) -> None:
    _skipped(w, "gate", "gate")


def still_red(w: World) -> None:
    open_red(w, {"build": ref(11)}, "2026-10-20T09:00:00Z")
    w.runs = [w.run(13, "failure", "2026-10-20T11:00:00Z"), w.green(12, "2026-10-20T10:00:00Z", ["lint", "other"]),
              w.run(11, "failure", "2026-10-20T09:00:00Z")]
    w.jobs(13, [("build", "failure"), ("lint", "success")])


def issue_beyond_100(w: World) -> None:
    filler = [{"number": 900 + n, "state": "closed", "body": "no mark"} for n in range(100)]
    w.pages = {1: filler, 2: [issue(5, "open", "2026-10-20T10:00:00Z", {"build": ref(11)})]}
    w.runs = [w.green(12, "2026-10-20T11:00:00Z", ["build"]), w.run(11, "failure", "2026-10-20T10:00:00Z")]


def _flaky_jobs(w: World, failures: int) -> None:
    red_today(w)
    key = f"{R}/Fam/actions/runs/12/jobs?filter=latest&per_page=100&page=1"
    w.answers[key] = {"http_errors": [502] * failures, "answer": w.answers[key]}


def jobs_5xx_recovers(w: World) -> None:
    _flaky_jobs(w, 4)


def jobs_5xx_never(w: World) -> None:
    """Fam's jobs page never recovers; Second, read after it, must still settle."""
    _flaky_jobs(w, 5)
    w.repos.append({"name": "Second", "fork": False, "archived": False, "default_branch": "develop"})
    second = [w.run(22, "failure", "2026-10-20T11:00:00Z", repo="Second")]
    w.jobs(22, [("build", "failure")], repo="Second")
    w.answers[f"{R}/Second/actions/runs?branch=develop&status=completed&per_page=100"] = {"workflow_runs": second}
    w.answers[f"{R}/Second/actions/workflows/7/runs?branch=develop&status=completed&per_page=100"] = {"workflow_runs": second}
    w.answers[f"{R}/Second/actions/workflows/7"] = {"id": 7, "path": ".github/workflows/lane.yml", "state": "active"}


SCENARIOS: dict[str, Callable[[World], None]] = {fn.__name__.replace("_", "-"): fn for fn in (
    red_opens, green_quiet, ignored_events, umbrella_masked, open_closes, other_lane_green, older_rerun,
    startup_failure, closed_floor, old_red_newest, workflow_deleted, workflow_disabled, missing_from_page,
    stale_page, job_retired, one_green_only, caller_skipped, job_skipped, still_red, issue_beyond_100,
    jobs_5xx_recovers, jobs_5xx_never)}


def main() -> int:
    world = World()
    SCENARIOS[sys.argv[1]](world)
    world.write(sys.argv[2])
    return 0


if __name__ == "__main__":
    sys.exit(main())
