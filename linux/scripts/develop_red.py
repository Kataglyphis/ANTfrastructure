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
import urllib.request

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


class Client:
    """GitHub REST over urllib; a replay file answers the GETs, and a dry run prints every write."""

    def __init__(self, token: str, dry_run: bool, replay: dict | None) -> None:
        self.token, self.dry_run, self.replay = token, dry_run, replay

    def call(self, method: str, path: str, body: dict | None = None):
        if method != "GET" and (self.dry_run or self.replay is not None):
            print("dry-run: %s %s %s" % (method, path, json.dumps(body, sort_keys=True)))
            return {}
        if self.replay is not None:
            if path not in self.replay:
                raise SystemExit("replay has no answer for GET %s" % path)
            return self.replay[path]
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(API + path, data=data, method=method)
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        if self.token:
            req.add_header("Authorization", "Bearer " + self.token)
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.load(resp)


def family_repos(client: Client) -> list[str]:
    """The family is the owner's own repositories on develop; forks and archived ones follow none of it."""
    repos = client.call("GET", "/users/%s/repos?type=owner&per_page=100" % OWNER)
    return sorted(r["name"] for r in repos
                  if not r["fork"] and not r["archived"] and r["default_branch"] == "develop")


def decisive_runs(client: Client, repo: str) -> dict[int, list[dict]]:
    path = "/repos/%s/%s/actions/runs?branch=develop&status=completed&per_page=100" % (OWNER, repo)
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
        path = "/repos/%s/%s/actions/runs/%d/jobs?filter=latest&per_page=100&page=%d" % (
            OWNER, repo, run_id, page)
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
    return {"open": is_open, "seen": mark["seen"], "red": mark["red"] if is_open else {}}


def window(runs: list[dict], state: dict, now: dt.datetime) -> list[dict]:
    """The runs that finished after the issue last looked, newest first; without an open issue, only if one is red."""
    if state["open"]:
        return [r for r in runs if r["updated_at"] > state["seen"]][:WALK]
    floor = max(state["seen"], (now - LOOKBACK).strftime(ISO))
    # The newest run counts however old it is, so a lane red before this watch existed is found.
    newer = [r for r in runs if r["updated_at"] > floor
             or (r is runs[0] and r["updated_at"] > state["seen"])]
    if not any(r["conclusion"] in RED for r in newer):
        return []
    return newer[:WALK]


def verdict(state: dict, walked: list[dict], jobs_of) -> dict:
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
                red[job] = {"run": run["id"], "url": run["html_url"], "sha": run["head_sha"][:8]}
    seen = max([state["seen"]] + [r["updated_at"] for r in walked])
    return {"open": state["open"], "seen": seen, "red": red}


def body(repo: str, newest: dict, workflow_id: int, new: dict) -> str:
    lines = ["`develop` of [%s](https://github.com/%s/%s) is red in **%s** (`%s`):" % (
        repo, OWNER, repo, newest["name"], newest["path"]), ""]
    for job, ref in sorted(new["red"].items()):
        lines.append("- `%s`: last failed in [run %d](%s) at `%s`" % (job, ref["run"], ref["url"], ref["sha"]))
    mark = {"repo": repo, "workflow_id": workflow_id, "seen": new["seen"], "red": new["red"]}
    lines += ["", "Closes itself once each job above passed on `develop` again (`develop-red.yml`). "
              "A job that was renamed or removed never passes again: close the issue by hand.",
              "", MARK + json.dumps(mark, sort_keys=True) + " -->"]
    return "\n".join(lines)


def settle(client: Client, repo: str, runs: list[dict], issue: dict | None, now: dt.datetime) -> None:
    state = issue_state(issue)
    walked = window(runs, state, now)
    if not walked:
        return
    new = verdict(state, walked, lambda run: run_jobs(client, repo, run["id"]))
    title = "develop is red: %s · %s" % (repo, runs[0]["name"])
    text = body(repo, runs[0], runs[0]["workflow_id"], new)
    issues = "/repos/%s/%s/issues" % (OWNER, HUB)
    if not state["open"]:
        if new["red"]:
            client.call("POST", issues, {"title": title, "body": text, "labels": [LABEL]})
            print("opened: %s" % title)
        return
    path = "%s/%d" % (issues, issue["number"])
    if not new["red"]:
        client.call("POST", path + "/comments", {"body": "Green again: every job passed on develop, "
                                                 "last in %s." % walked[0]["html_url"]})
        client.call("PATCH", path, {"state": "closed", "state_reason": "completed", "body": text})
        print("closed: %s" % title)
    elif new != state:
        client.call("PATCH", path, {"title": title, "body": text})
        print("updated: %s" % title)


def latest_issues(client: Client) -> dict[tuple[str, int], dict]:
    """The newest develop-red issue per workflow; a closed one marks how far the watch already looked."""
    path = "/repos/%s/%s/issues?labels=%s&state=all&sort=created&direction=desc&per_page=100" % (
        OWNER, HUB, LABEL)
    found: dict[tuple[str, int], dict] = {}
    for issue in client.call("GET", path):
        if "pull_request" in issue or MARK not in (issue.get("body") or ""):
            continue
        mark = json.loads(issue["body"].split(MARK, 1)[1].split(" -->", 1)[0])
        found.setdefault((mark["repo"], mark["workflow_id"]), issue)
    return found


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true", help="print the writes instead of making them")
    parser.add_argument("--replay", help="JSON file mapping each GET path to its answer (tests)")
    parser.add_argument("--now", help="the current time as %s (tests)" % ISO.replace("%", "%%"))
    args = parser.parse_args(argv)
    replay = None
    if args.replay:
        with open(args.replay, encoding="utf-8") as handle:
            replay = json.load(handle)
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or ""
    client = Client(token, args.dry_run, replay)
    now = (dt.datetime.strptime(args.now, ISO).replace(tzinfo=dt.timezone.utc) if args.now
           else dt.datetime.now(dt.timezone.utc))
    issues = latest_issues(client)
    for repo in family_repos(client):
        for workflow_id, runs in sorted(decisive_runs(client, repo).items()):
            settle(client, repo, runs, issues.get((repo, workflow_id)), now)
    return 0


if __name__ == "__main__":
    sys.exit(main())
