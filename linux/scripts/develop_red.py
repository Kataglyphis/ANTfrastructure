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
# A GET is safe to repeat, and one 502 from the API must not turn the watch itself red.
RETRY_DELAYS = (5, 15)


class Client:
    """GitHub REST over urllib; a replay file answers the GETs, and a dry run prints every write."""

    def __init__(self, token: str, dry_run: bool, replay: dict | None) -> None:
        self.token, self.dry_run, self.replay = token, dry_run, replay

    def call(self, method: str, path: str, body: dict | None = None) -> Any:
        if method != "GET" and (self.dry_run or self.replay is not None):
            print(f"dry-run: {method} {path} {json.dumps(body, sort_keys=True)}")
            return {}
        if self.replay is not None:
            if path not in self.replay:
                raise SystemExit(f"replay has no answer for GET {path}")
            return self.replay[path]
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(API + path, data=data, method=method)
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        if self.token:
            req.add_header("Authorization", "Bearer " + self.token)
        for delay in (*RETRY_DELAYS, None):
            try:
                with urllib.request.urlopen(req, timeout=60) as resp:
                    return json.load(resp)
            except urllib.error.HTTPError as error:
                if method != "GET" or error.code < 500 or delay is None:
                    raise
                print(f"retrying GET {path} after HTTP {error.code}", file=sys.stderr)
                time.sleep(delay)
        raise AssertionError("unreachable")


def family_repos(client: Client) -> list[str]:
    """The family is the owner's own repositories on develop; forks and archived ones follow none of it."""
    repos = client.call("GET", f"/users/{OWNER}/repos?type=owner&per_page=100")
    return sorted(
        r["name"]
        for r in repos
        if not r["fork"] and not r["archived"] and r["default_branch"] == "develop"
    )


def decisive_runs(client: Client, repo: str) -> dict[int, list[dict]]:
    path = f"/repos/{OWNER}/{repo}/actions/runs?branch=develop&status=completed&per_page=100"
    by_workflow: dict[int, list[dict]] = {}
    for run in client.call("GET", path)["workflow_runs"]:
        if run["event"] in EVENTS and run["conclusion"] in RED | GREEN:
            by_workflow.setdefault(run["workflow_id"], []).append(run)
    for runs in by_workflow.values():
        runs.sort(key=lambda r: r["id"], reverse=True)
    return by_workflow


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
            "A job that was renamed or removed never passes again: close the issue by hand."
        ),
        "",
        MARK + json.dumps(mark, sort_keys=True) + " -->",
    ]
    return "\n".join(lines)


def settle(
    client: Client, repo: str, runs: list[dict], issue: dict | None, now: dt.datetime
) -> None:
    state = issue_state(issue)
    walked = window(runs, state, now)
    if not walked:
        return
    new = verdict(state, walked, lambda run: run_jobs(client, repo, run["id"]))
    title = f"develop is red: {repo} · {runs[0]['name']}"
    text = body(repo, runs[0], runs[0]["workflow_id"], new)
    issues = f"/repos/{OWNER}/{HUB}/issues"
    if not state["open"]:
        if new["red"]:
            client.call(
                "POST", issues, {"title": title, "body": text, "labels": [LABEL]}
            )
            print(f"opened: {title}")
        return
    if issue is None:
        raise RuntimeError("an open issue has no issue record")
    path = f"{issues}/{issue['number']}"
    if not new["red"]:
        client.call(
            "POST",
            path + "/comments",
            {
                "body": "Green again: every job passed on develop, "
                f"last in {walked[0]['html_url']}."
            },
        )
        client.call(
            "PATCH",
            path,
            {"state": "closed", "state_reason": "completed", "body": text},
        )
        print(f"closed: {title}")
    elif new != state:
        client.call("PATCH", path, {"title": title, "body": text})
        print(f"updated: {title}")


def latest_issues(client: Client) -> dict[tuple[str, int], dict]:
    """The newest develop-red issue per workflow; a closed one marks how far the watch already looked."""
    path = f"/repos/{OWNER}/{HUB}/issues?labels={LABEL}&state=all&sort=created&direction=desc&per_page=100"
    found: dict[tuple[str, int], dict] = {}
    for issue in client.call("GET", path):
        if "pull_request" in issue or MARK not in (issue.get("body") or ""):
            continue
        mark = json.loads(issue["body"].split(MARK, 1)[1].split(" -->", 1)[0])
        found.setdefault((mark["repo"], mark["workflow_id"]), issue)
    return found


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
    repos, watched = family_repos(client), 0
    for repo in repos:
        for workflow_id, runs in sorted(decisive_runs(client, repo).items()):
            settle(client, repo, runs, issues.get((repo, workflow_id)), now)
            watched += 1
    # A silent run must still say what it read, or a token that sees nothing looks like a green family.
    print(
        f"watched: {watched} workflow(s) in {len(repos)} repositories: {' '.join(repos)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
