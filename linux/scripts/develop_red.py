#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""One hub issue per family workflow whose develop run is red, closed once each red job passed again.

Usage: develop_red.py [--dry-run] [--replay FILE] [--now ISO]; see docs/github-cli-pipeline-monitoring.md#a-red-develop-opens-an-issue
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import time
import urllib.error
import urllib.request
from collections.abc import Callable
from email.message import Message
from typing import Any

OWNER = "Kataglyphis"
HUB = "ANTfrastructure"
LABEL = "develop-red"
RED = frozenset({"failure", "timed_out", "startup_failure"})
GREEN = frozenset({"success"})
# Pull requests test a merge, not develop; cancelled and skipped runs prove nothing either way.
EVENTS = frozenset({"push", "workflow_dispatch", "schedule"})
WHOLE = "(the run itself)"
LOOKBACK = dt.timedelta(hours=24)
WALK = 10
MARK = "<!-- develop-red "
ISO = "%Y-%m-%dT%H:%M:%SZ"
API = "https://api.github.com"
# A GET is safe to repeat; four delays (75 s) outlast a GitHub 5xx burst and fit the 10-minute job.
RETRY_DELAYS = (5, 10, 20, 40)
ISSUE_PAGE = 100
ACTIVE = "active"


class Client:
    """GitHub REST over urllib; a replay file answers the GETs, and a dry run prints every write."""

    def __init__(self, token: str, dry_run: bool, replay: dict | None) -> None:
        self.token, self.dry_run, self.replay = token, dry_run, replay
        # A replay answers at once, so its retries need no wait.
        self.sleep: Callable[[float], None] = time.sleep if replay is None else (lambda _s: None)

    def _replayed(self, path: str) -> Any:
        """A replay answer, or the next of its recorded 5xx codes: {"http_errors": [502, ...], "answer": ...}."""
        if self.replay is None or path not in self.replay:
            raise SystemExit(f"replay has no answer for GET {path}")
        answer = self.replay[path]
        if isinstance(answer, dict) and "http_errors" in answer:
            if answer["http_errors"]:
                raise urllib.error.HTTPError(API + path, answer["http_errors"].pop(0), "replayed", Message(), None)
            return answer["answer"]
        return answer

    def _fetch(self, method: str, path: str, body: dict | None) -> Any:
        if self.replay is not None:
            return self._replayed(path)
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(API + path, data=data, method=method)
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        if self.token:
            req.add_header("Authorization", "Bearer " + self.token)
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.load(resp)

    def call(self, method: str, path: str, body: dict | None = None) -> Any:
        if method != "GET" and (self.dry_run or self.replay is not None):
            print(f"dry-run: {method} {path} {json.dumps(body, sort_keys=True)}")
            return {}
        for delay in (*RETRY_DELAYS, None):
            try:
                return self._fetch(method, path, body)
            except urllib.error.HTTPError as error:
                if method != "GET" or error.code < 500 or delay is None:
                    raise
                print(f"retrying GET {path} after HTTP {error.code}", file=sys.stderr)
                self.sleep(delay)
        raise AssertionError("unreachable")


def family_repos(client: Client) -> list[str]:
    """The family is the owner's own repositories on develop; forks and archived ones follow none of it."""
    repos = client.call("GET", f"/users/{OWNER}/repos?type=owner&per_page=100")
    return sorted(
        r["name"]
        for r in repos
        if not r["fork"] and not r["archived"] and r["default_branch"] == "develop"
    )


def _decisive(runs: list[dict]) -> dict[int, list[dict]]:
    by_workflow: dict[int, list[dict]] = {}
    for run in runs:
        if run["event"] in EVENTS and run["conclusion"] in RED | GREEN:
            by_workflow.setdefault(run["workflow_id"], []).append(run)
    for found in by_workflow.values():
        found.sort(key=lambda r: r["id"], reverse=True)
    return by_workflow


def decisive_runs(client: Client, repo: str) -> dict[int, list[dict]]:
    path = f"/repos/{OWNER}/{repo}/actions/runs?branch=develop&status=completed&per_page=100"
    return _decisive(client.call("GET", path)["workflow_runs"])


def workflow_runs(client: Client, repo: str, workflow_id: int) -> list[dict]:
    """One workflow's own develop runs: the repo-wide page holds 100 runs of all workflows and can miss or lag one."""
    path = f"/repos/{OWNER}/{repo}/actions/workflows/{workflow_id}/runs?branch=develop&status=completed&per_page=100"
    return _decisive(client.call("GET", path)["workflow_runs"]).get(workflow_id, [])


def workflow_state(client: Client, repo: str, workflow_id: int) -> dict:
    """The workflow record: a deleted or disabled one never runs again, so its jobs can never pass."""
    return client.call("GET", f"/repos/{OWNER}/{repo}/actions/workflows/{workflow_id}")


def run_jobs(client: Client, repo: str, run_id: int) -> dict[str, str]:
    jobs: dict[str, str] = {}
    page, fetched = 1, 0
    while True:
        path = f"/repos/{OWNER}/{repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=100&page={page}"
        data = client.call("GET", path)
        for job in data["jobs"]:
            if jobs.get(job["name"]) not in RED:
                jobs[job["name"]] = job["conclusion"]
        fetched += len(data["jobs"])
        if fetched >= data["total_count"] or not data["jobs"]:
            return jobs
        page += 1


def outcomes(run: dict, jobs: dict[str, str]) -> dict[str, str]:
    """Each job's verdict in one run; WHOLE stands for a red run with no red job, as a startup failure has none."""
    ran = {name: c for name, c in jobs.items() if c in RED | GREEN}
    if run["conclusion"] in GREEN:
        # A job allowed to fail (continue-on-error) leaves the run green, so the run decides.
        return dict.fromkeys(list(ran) + [WHOLE], "success")
    if not RED & set(ran.values()):
        ran[WHOLE] = run["conclusion"]
    return ran


def issue_state(issue: dict | None) -> dict:
    if issue is None:
        return {"open": False, "seen": "", "red": {}}
    mark = json.loads(issue["body"].split(MARK, 1)[1].split(" -->", 1)[0])
    is_open = issue["state"] == "open"
    return {
        "open": is_open,
        "seen": mark["seen"],
        "red": mark["red"] if is_open else {},
    }


def window(runs: list[dict], state: dict, now: dt.datetime) -> list[dict]:
    """The runs that finished after the issue last looked, newest first; without an open issue, only if one is red."""
    if state["open"]:
        return [r for r in runs if r["updated_at"] > state["seen"]][:WALK]
    floor = max(state["seen"], (now - LOOKBACK).strftime(ISO))
    # The newest run counts however old it is, so a lane red before this watch existed is found.
    newer = [
        r
        for r in runs
        if r["updated_at"] > floor or (r is runs[0] and r["updated_at"] > state["seen"])
    ]
    if not any(r["conclusion"] in RED for r in newer):
        return []
    return newer[:WALK]


def verdict(
    state: dict, walked: list[dict], jobs_of: Callable[[dict[str, Any]], dict[str, str]]
) -> dict:
    """The newest run that ran a job decides it; an older re-run never overrides a newer red."""
    red = dict(state["red"])
    decided: set[str] = set()
    for run in walked:
        for job, conclusion in outcomes(run, jobs_of(run)).items():
            if job in decided or run["id"] < red.get(job, {}).get("run", 0):
                continue
            decided.add(job)
            if conclusion in GREEN:
                red.pop(job, None)
            else:
                red[job] = {
                    "run": run["id"],
                    "url": run["html_url"],
                    "sha": run["head_sha"][:8],
                }
    seen = max([state["seen"]] + [r["updated_at"] for r in walked])
    return {"open": state["open"], "seen": seen, "red": red}


def caller_ran(job: str, jobs: dict[str, str]) -> bool:
    """A nested 'A / B' can only be gone from a run in which its caller A ran; a skipped caller hides every nested job."""
    if " / " not in job:
        return True
    prefix = job.split(" / ", 1)[0] + " / "
    return any(name.startswith(prefix) and c in RED | GREEN for name, c in jobs.items())


def retired(red: dict, runs: list[dict], jobs_of: Callable[[dict[str, Any]], dict[str, str]]) -> dict[str, list[int]]:
    """Red jobs absent, not skipped, from two green runs newer than their red one: renamed or removed, they never pass."""
    gone: dict[str, list[int]] = {}
    for job, ref in red.items():
        if job == WHOLE:
            continue
        greens = [r for r in runs if r["id"] > ref["run"] and r["conclusion"] in GREEN][:WALK]
        proof = [r["id"] for r in greens if job not in jobs_of(r) and caller_ran(job, jobs_of(r))]
        if len(proof) >= 2:
            gone[job] = proof[:2]
    return gone


def body(repo: str, newest: dict, workflow_id: int, new: dict) -> str:
    lines = [
        (
            f"`develop` of [{repo}](https://github.com/{OWNER}/{repo}) "
            f"is red in **{newest['name']}** (`{newest['path']}`):"
        ),
        "",
    ]
    for job, ref in sorted(new["red"].items()):
        lines.append(
            f"- `{job}`: last failed in [run {ref['run']}]({ref['url']}) at `{ref['sha']}`"
        )
    mark = {
        "repo": repo,
        "workflow_id": workflow_id,
        "seen": new["seen"],
        "red": new["red"],
    }
    lines += [
        "",
        (
            "Closes itself once each job above passed on `develop` again (`develop-red.yml`). "
            "A job that two newer green runs no longer have is retired, and a deleted or disabled "
            "workflow closes its issue."
        ),
        "",
        MARK + json.dumps(mark, sort_keys=True) + " -->",
    ]
    return "\n".join(lines)


def _retired_note(gone: dict[str, list[int]]) -> str:
    return "".join(f" Retired `{job}`: absent from the newer green runs {' and '.join(map(str, runs))}."
                   for job, runs in sorted(gone.items()))


def close_issue(client: Client, issue: dict, comment: str, text: str | None, reason: str) -> None:
    path = f"/repos/{OWNER}/{HUB}/issues/{issue['number']}"
    client.call("POST", path + "/comments", {"body": comment})
    change = {"state": "closed", "state_reason": reason}
    client.call("PATCH", path, change if text is None else {**change, "body": text})


def settle(
    client: Client, repo: str, runs: list[dict], issue: dict | None, now: dt.datetime
) -> None:
    state = issue_state(issue)
    walked = window(runs, state, now)
    if not walked:
        return
    cache: dict[int, dict[str, str]] = {}

    def jobs_of(run: dict[str, Any]) -> dict[str, str]:
        if run["id"] not in cache:
            cache[run["id"]] = run_jobs(client, repo, run["id"])
        return cache[run["id"]]

    new = verdict(state, walked, jobs_of)
    gone = retired(new["red"], runs, jobs_of)
    new["red"] = {job: ref for job, ref in new["red"].items() if job not in gone}
    title = f"develop is red: {repo} · {runs[0]['name']}"
    text = body(repo, runs[0], runs[0]["workflow_id"], new)
    if not state["open"]:
        if new["red"] and workflow_state(client, repo, runs[0]["workflow_id"]).get("state") == ACTIVE:
            client.call("POST", f"/repos/{OWNER}/{HUB}/issues", {"title": title, "body": text, "labels": [LABEL]})
            print(f"opened: {title}")
        return
    if issue is None:
        raise RuntimeError("an open issue has no issue record")
    if not new["red"]:
        passed = "every red job passed on develop or was retired" if gone else "every job passed on develop"
        close_issue(client, issue, f"Green again: {passed}, last in {walked[0]['html_url']}."
                    + _retired_note(gone), text, "completed")
        print(f"closed: {title}")
    elif new != state:
        client.call("PATCH", f"/repos/{OWNER}/{HUB}/issues/{issue['number']}", {"title": title, "body": text})
        print(f"updated: {title}")


def settle_workflow(
    client: Client, repo: str, workflow_id: int, page: list[dict] | None, issue: dict | None, now: dt.datetime
) -> None:
    """One workflow's issue; the per-workflow list confirms what the repo-wide page shows before anything is written."""
    state = issue_state(issue)
    if state["open"]:
        record = workflow_state(client, repo, workflow_id)
        if record.get("state") != ACTIVE:
            close_issue(client, issue or {}, f"The workflow `{record.get('path', workflow_id)}` is "
                        f"{record.get('state', 'gone')}: it runs no more, so its jobs can never pass on develop.",
                        None, "not_planned")
            print(f"closed: {repo} workflow {workflow_id} is {record.get('state', 'gone')}")
            return
    # An open issue always reads its workflow's own runs: a stale page would hold it open for good.
    if state["open"] or page is None or window(page, state, now):
        page = workflow_runs(client, repo, workflow_id)
    if page:
        settle(client, repo, page, issue, now)


def settle_repo(client: Client, repo: str, issues: dict[tuple[str, int], dict], now: dt.datetime) -> int:
    """Every workflow on the repo-wide page plus every workflow with an open issue, which may be missing from it."""
    page = decisive_runs(client, repo)
    open_ids = {wid for (name, wid), issue in issues.items() if name == repo and issue["state"] == "open"}
    for workflow_id in sorted(set(page) | open_ids):
        settle_workflow(client, repo, workflow_id, page.get(workflow_id), issues.get((repo, workflow_id)), now)
    return len(set(page) | open_ids)


def latest_issues(client: Client) -> dict[tuple[str, int], dict]:
    """The newest develop-red issue per workflow, over every page; a closed one marks how far the watch already looked."""
    found: dict[tuple[str, int], dict] = {}
    page = 1
    while True:
        path = (f"/repos/{OWNER}/{HUB}/issues?labels={LABEL}&state=all&sort=created&direction=desc"
                f"&per_page={ISSUE_PAGE}&page={page}")
        batch = client.call("GET", path)
        for issue in batch:
            if "pull_request" in issue or MARK not in (issue.get("body") or ""):
                continue
            mark = json.loads(issue["body"].split(MARK, 1)[1].split(" -->", 1)[0])
            found.setdefault((mark["repo"], mark["workflow_id"]), issue)
        if len(batch) < ISSUE_PAGE:
            return found
        page += 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--dry-run", action="store_true", help="print the writes instead of making them"
    )
    parser.add_argument(
        "--replay", help="JSON file mapping each GET path to its answer (tests)"
    )
    parser.add_argument(
        "--now", help=f"the current time as {ISO.replace('%', '%%')} (tests)"
    )
    args = parser.parse_args(argv)
    replay = None
    if args.replay:
        with open(args.replay, encoding="utf-8") as handle:
            replay = json.load(handle)
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or ""
    client = Client(token, args.dry_run, replay)
    now = (
        dt.datetime.strptime(args.now, ISO).replace(tzinfo=dt.UTC)
        if args.now
        else dt.datetime.now(dt.UTC)
    )
    issues = latest_issues(client)
    repos, watched, failed = family_repos(client), 0, []
    for repo in repos:
        try:
            watched += settle_repo(client, repo, issues, now)
        except (urllib.error.URLError, TimeoutError) as error:
            # One repository the API cannot answer must not leave the others unwatched.
            failed.append(repo)
            print(f"failed: {repo}: {error}", file=sys.stderr)
    # A silent run must still say what it read, or a token that sees nothing looks like a green family.
    print(
        f"watched: {watched} workflow(s) in {len(repos)} repositories: {' '.join(repos)}"
    )
    if failed:
        print(f"FAILED: the API never answered for {' '.join(failed)}", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
