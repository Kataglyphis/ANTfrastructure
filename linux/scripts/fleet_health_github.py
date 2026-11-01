# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""External fleet-health metrics through develop_red.py's GitHub client; it reads GitHub state and judges none of it.
It does not follow Dependabot's cursor pages or read private repositories without a token; see docs/fleet-health.md#metrics"""

from __future__ import annotations

import datetime as dt
import json
import os
import statistics
import urllib.error
from collections.abc import Callable
from typing import Any

import develop_red
import quality_report_github as github

OWNER, HUB = develop_red.OWNER, develop_red.HUB
CODE, REPORT, EXTERNAL, ADVISORY = "code", "report", "external", "advisory"
COLLECTED, NOT_COLLECTED, FAILED = "collected", "not-collected", "failed"
LOWER, HIGHER = "lower", "higher"
RUNS = 20
PAGE = 100
MAX_PAGES = 10
UNREADABLE = (401, 403, 404)
SEVERITIES = ("critical", "high", "medium", "low")
AUDIT_SEVERITIES = ("CRITICAL", "HIGH", "MODERATE", "LOW")
HIGH_CRITICAL = frozenset({"critical", "high"})
MEASUREMENTS = github.MEASUREMENTS_ARTIFACT
RECORD = "fleet-health-json"
WORKFLOW = "fleet-health.yml"
ISSUE_LABEL = "fleet-health"
Metrics = dict[str, dict[str, Any]]


class NotCollected(Exception):
    """GitHub refused or lacks the data (no token, 401, 403, 404): the metric is not collected."""


class Failed(Exception):
    """A 5xx or timeout outlived the client's bounded retry: the measurement failed."""


def rec(value: Any, unit: str, better: str, klass: str, source: str,
        members: list[str] | None = None) -> dict[str, Any]:
    """One collected metric record."""
    row: dict[str, Any] = {"value": value, "unit": unit, "better": better, "class": klass,
                           "source": source, "status": COLLECTED}
    if members is not None:
        row["members"] = sorted(set(members))
    return row


def gap(status: str, unit: str, better: str, klass: str, source: str, reason: str) -> dict[str, Any]:
    """A metric that is not collected or whose measurement failed: never a value."""
    return {"value": None, "unit": unit, "better": better, "class": klass, "source": source,
            "status": status, "reason": reason}


def mapped(read: Callable[[], Any], what: str) -> Any:
    """One client read; refusals become NotCollected and exhausted retries Failed."""
    try:
        return read()
    except urllib.error.HTTPError as error:
        if error.code in UNREADABLE:
            raise NotCollected(f"HTTP {error.code} for {what}") from None
        raise Failed(f"HTTP {error.code} for {what} after the client's retries") from None
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise Failed(f"{what}: {error}") from None


def get(client: develop_red.Client, path: str) -> Any:
    """One GET through mapped()."""
    return mapped(lambda: client.call("GET", path), path)


def guarded(names: dict[str, tuple[str, str, str]], source: str,
            collect: Callable[[], Metrics]) -> Metrics:
    """Run one collector; on a refusal or failure every name it owns gets that status."""
    try:
        return collect()
    except NotCollected as exc:
        status, reason = NOT_COLLECTED, str(exc)
    except Failed as exc:
        status, reason = FAILED, str(exc)
    return {name: gap(status, unit, better, klass, source, reason)
            for name, (unit, better, klass) in names.items()}


def need(token: str) -> None:
    """Alert endpoints answer nobody anonymous, so no token means not collected."""
    if not token:
        raise NotCollected("no token: set FLEET_HEALTH_TOKEN or log in with gh")


def paged(client: develop_red.Client, path: str) -> list[dict[str, Any]]:
    """Every row of a page-numbered list, up to MAX_PAGES pages."""
    rows: list[dict[str, Any]] = []
    for page in range(1, MAX_PAGES + 1):
        batch = get(client, f"{path}&per_page={PAGE}&page={page}")
        rows += batch
        if len(batch) < PAGE:
            return rows
    raise Failed(f"{path} has more than {MAX_PAGES * PAGE} rows")


def minutes(run: dict[str, Any]) -> float:
    """Wall minutes from a run's start to its last update."""
    start = dt.datetime.fromisoformat(run.get("run_started_at") or run["created_at"])
    return (dt.datetime.fromisoformat(run["updated_at"]) - start).total_seconds() / 60


def ci_runs(client: develop_red.Client, repo: str) -> Metrics:
    """Success rate and median minutes of each active workflow's last 20 decisive develop runs."""
    def collect() -> Metrics:
        found: Metrics = {}
        workflows = get(client, f"/repos/{OWNER}/{repo}/actions/workflows?per_page={PAGE}")["workflows"]
        for workflow in sorted(workflows, key=lambda w: w["path"]):
            if workflow.get("state") != develop_red.ACTIVE:
                continue
            runs = mapped(lambda w=workflow: develop_red.workflow_runs(client, repo, w["id"]),
                          f"the develop runs of {workflow['path']}")[:RUNS]
            if not runs:
                continue
            name, source = os.path.basename(workflow["path"]), f"last {len(runs)} develop runs"
            rate = 100 * sum(r["conclusion"] == "success" for r in runs) / len(runs)
            found[f"ci.{name}.success_rate"] = rec(round(rate, 1), "%", HIGHER, EXTERNAL, source)
            found[f"ci.{name}.median_minutes"] = rec(
                round(statistics.median(minutes(r) for r in runs), 1), "min", LOWER, EXTERNAL, source)
        return found
    return guarded({"ci": ("runs", HIGHER, EXTERNAL)}, "actions/workflows", collect)


def _severity_names(prefix: str, levels: tuple[str, ...]) -> dict[str, tuple[str, str, str]]:
    return {f"{prefix}.open.{level.lower()}": ("alerts", LOWER, EXTERNAL) for level in levels}


def dependabot(client: develop_red.Client, repo: str, token: str) -> Metrics:
    """Open Dependabot alerts by severity, and the HIGH or CRITICAL advisory ids among them."""
    names = _severity_names("dependabot", SEVERITIES)
    names["dependabot.high_critical_ids"] = ("advisories", LOWER, ADVISORY)
    source = "dependabot/alerts?state=open"

    def collect() -> Metrics:
        need(token)
        alerts = get(client, f"/repos/{OWNER}/{repo}/dependabot/alerts?state=open&per_page={PAGE}")
        if len(alerts) >= PAGE:
            raise NotCollected(f"{PAGE} or more open alerts; cursor pages are not followed")
        levels = [a["security_advisory"]["severity"] for a in alerts]
        found = {f"dependabot.open.{s}": rec(levels.count(s), "alerts", LOWER, EXTERNAL, source)
                 for s in SEVERITIES}
        ids = [a["security_advisory"]["ghsa_id"] for a in alerts
               if a["security_advisory"]["severity"] in HIGH_CRITICAL]
        found["dependabot.high_critical_ids"] = rec(len(set(ids)), "advisories", LOWER, ADVISORY,
                                                    source, ids)
        return found
    return guarded(names, source, collect)


def code_scanning(client: develop_red.Client, repo: str, token: str,
                  exists: Callable[[str], bool] | None, now: dt.datetime) -> Metrics:
    """Open code-scanning alerts by severity, those on paths absent from the tree, and the newest analysis's age."""
    names = _severity_names("code_scanning", (*SEVERITIES, "other"))
    names["code_scanning.open_on_absent_paths"] = ("alerts", LOWER, EXTERNAL)
    names["code_scanning.days_since_analysis"] = ("days", LOWER, EXTERNAL)
    source = "code-scanning/alerts?state=open"

    def collect() -> Metrics:
        need(token)
        alerts = paged(client, f"/repos/{OWNER}/{repo}/code-scanning/alerts?state=open")
        levels = [(a["rule"].get("security_severity_level") or "other") for a in alerts]
        found = {f"code_scanning.open.{s}": rec(levels.count(s), "alerts", LOWER, EXTERNAL, source)
                 for s in (*SEVERITIES, "other")}
        paths = [a["most_recent_instance"]["location"]["path"] for a in alerts]
        found["code_scanning.open_on_absent_paths"] = (
            rec(sum(not exists(p) for p in paths), "alerts", LOWER, EXTERNAL, source)
            if exists else gap(NOT_COLLECTED, "alerts", LOWER, EXTERNAL, source, "no checkout"))
        analyses = get(client, f"/repos/{OWNER}/{repo}/code-scanning/analyses?per_page=1")
        newest = dt.datetime.fromisoformat(analyses[0]["created_at"]) if analyses else None
        found["code_scanning.days_since_analysis"] = (
            rec(round((now - newest).total_seconds() / 86400, 1), "days", LOWER, EXTERNAL,
                "code-scanning/analyses") if newest else
            gap(NOT_COLLECTED, "days", LOWER, EXTERNAL, "code-scanning/analyses", "no analysis yet"))
        return found
    return guarded(names, source, collect)


def secret_scanning(client: develop_red.Client, repo: str, token: str) -> Metrics:
    """Open secret-scanning alerts; GitHub grades them by type, not severity."""
    names = {"secret_scanning.open": ("alerts", LOWER, EXTERNAL)}
    source = "secret-scanning/alerts?state=open"

    def collect() -> Metrics:
        need(token)
        alerts = paged(client, f"/repos/{OWNER}/{repo}/secret-scanning/alerts?state=open")
        return {"secret_scanning.open": rec(len(alerts), "alerts", LOWER, EXTERNAL, source)}
    return guarded(names, source, collect)


def develop_red_issues(client: develop_red.Client, repo: str,
                       cache: dict[str, Any]) -> Metrics:
    """Open develop-red hub issues naming this repo; the issue list is read once per run."""
    def collect() -> Metrics:
        if "issues" not in cache:
            cache["issues"] = mapped(lambda: develop_red.latest_issues(client),
                                     f"the {develop_red.LABEL} issues")
        count = sum(1 for (name, _wid), issue in cache["issues"].items()
                    if name == repo and issue["state"] == "open")
        return {"develop_red.open_issues": rec(count, "issues", LOWER, EXTERNAL,
                                               f"{HUB} issues labelled {develop_red.LABEL}")}
    return guarded({"develop_red.open_issues": ("issues", LOWER, EXTERNAL)}, "issues", collect)


def hub_pin_lag(client: develop_red.Client, pin: str | None) -> Metrics:
    """Commits on the hub's develop that the repo's third_party/ANTfrastructure gitlink lacks."""
    names = {"hub_pin.lag_commits": ("commits", LOWER, EXTERNAL)}

    def collect() -> Metrics:
        if not pin:
            raise NotCollected("no third_party/ANTfrastructure gitlink in the checkout")
        ahead = get(client, f"/repos/{OWNER}/{HUB}/compare/{pin}...develop")["ahead_by"]
        return {"hub_pin.lag_commits": rec(ahead, "commits", LOWER, EXTERNAL,
                                           f"compare {pin[:12]}...develop")}
    return guarded(names, "compare", collect)


def newest_artifact(client: develop_red.Client, slug: str, name: str,
                    keep: Callable[[dict[str, Any]], bool]) -> dict[str, Any] | None:
    """The newest unexpired artifact of that exact name whose run passes `keep`."""
    rows = get(client, f"/repos/{slug}/actions/artifacts?name={name}&per_page={PAGE}")["artifacts"]
    for row in sorted(rows, key=lambda a: a.get("created_at", ""), reverse=True):
        if not row.get("expired") and keep(row.get("workflow_run") or {}):
            return row
    return None


def download(client: develop_red.Client, slug: str, artifact: dict[str, Any], dest: str) -> str:
    """One artifact's files in dest; a replay holds them under `ARTIFACT <slug> <id>`."""
    target = os.path.join(dest, f"{slug.replace('/', '_')}-{artifact['id']}")
    if client.replay is not None:
        files = client.replay.get(f"ARTIFACT {slug} {artifact['id']}")
        if files is None:
            raise Failed(f"replay has no files for artifact {artifact['id']}")
        os.makedirs(target, exist_ok=True)
        for rel, body in files.items():
            with open(os.path.join(target, rel), "w", encoding="utf-8") as fh:
                fh.write(body if isinstance(body, str) else json.dumps(body))
        return target
    run = artifact.get("workflow_run") or {}
    try:
        github.download(slug, int(run["id"]), artifact["name"], target)
    except github.Unavailable as exc:
        raise NotCollected(str(exc)) from None
    except github.Broken as exc:
        refused = any(f"HTTP {code}" in str(exc) for code in UNREADABLE)
        raise (NotCollected if refused else Failed)(str(exc)) from None
    return target


def read_json(directory: str, name: str | None = None) -> Any:
    """The named JSON file of a downloaded artifact, or its only one."""
    names = [name] if name else sorted(f for f in os.listdir(directory) if f.endswith(".json"))
    if len(names) != 1 or not os.path.isfile(os.path.join(directory, names[0])):
        raise Failed(f"artifact in {directory} holds no single {name or '*.json'}")
    try:
        with open(os.path.join(directory, names[0]), encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as exc:
        raise Failed(f"{names[0]} is unreadable: {exc}") from None


def on_develop(run: dict[str, Any]) -> bool:
    return run.get("head_branch") == "develop"


def security_audit(client: develop_red.Client, repo: str, dest: str) -> Metrics:
    """The newest develop security-audit verdict, its findings by severity and its HIGH or CRITICAL ids."""
    names = {f"security_audit.findings.{s.lower()}": ("findings", LOWER, EXTERNAL)
             for s in AUDIT_SEVERITIES}
    names["security_audit.verdict"] = ("verdict", LOWER, EXTERNAL)
    names["security_audit.high_critical_ids"] = ("advisories", LOWER, ADVISORY)

    def collect() -> Metrics:
        found = newest_artifact(client, f"{OWNER}/{repo}", "security-audit", on_develop)
        if found is None:
            raise NotCollected("no develop run carries a security-audit artifact")
        doc = read_json(download(client, f"{OWNER}/{repo}", found, dest), "security-audit.json")
        source = f"security-audit artifact of run {found['workflow_run']['id']}"
        levels = [f["severity"] for f in doc["findings"]]
        metrics = {f"security_audit.findings.{s.lower()}": rec(levels.count(s), "findings", LOWER,
                                                                EXTERNAL, source)
                   for s in AUDIT_SEVERITIES}
        metrics["security_audit.verdict"] = rec(doc["verdict"], "verdict", LOWER, EXTERNAL, source)
        ids = [f["id"] for f in doc["findings"] if f["severity"].lower() in HIGH_CRITICAL]
        metrics["security_audit.high_critical_ids"] = rec(len(set(ids)), "advisories", LOWER,
                                                          ADVISORY, source, ids)
        return metrics
    return guarded(names, "security-audit artifact", collect)


def bench_history(client: develop_red.Client, repo: str, keys: list[str], dest: str) -> Metrics:
    """The newest develop verdict of each bench-history artifact quality-report.toml declares."""
    if not keys:
        return {"bench_history": gap(NOT_COLLECTED, "verdict", LOWER, EXTERNAL, "quality-report.toml",
                                     "quality-report.toml declares no benchmark output")}
    metrics: Metrics = {}
    for key in keys:
        name = f"bench_history.{key}.verdict"

        def collect(key: str = key, name: str = name) -> Metrics:
            found = newest_artifact(client, f"{OWNER}/{repo}", key, on_develop)
            if found is None:
                raise NotCollected(f"no develop run carries a {key} artifact")
            doc = read_json(download(client, f"{OWNER}/{repo}", found, dest))
            return {name: rec(doc["verdict"], "verdict", LOWER, EXTERNAL,
                              f"{key} artifact of run {found['workflow_run']['id']}")}
        metrics.update(guarded({name: ("verdict", LOWER, EXTERNAL)}, f"{key} artifact", collect))
    return metrics


def ai_regression(client: develop_red.Client, repo: str) -> Metrics:
    """The conclusion of the newest completed develop run of ai-regression.yml."""
    names = {"ai_regression.verdict": ("verdict", LOWER, EXTERNAL)}

    def collect() -> Metrics:
        path = (f"/repos/{OWNER}/{repo}/actions/workflows/ai-regression.yml/runs"
                "?branch=develop&status=completed&per_page=1")
        runs = get(client, path)["workflow_runs"]
        if not runs:
            raise NotCollected("ai-regression.yml has no completed develop run")
        return {"ai_regression.verdict": rec(runs[0]["conclusion"], "verdict", LOWER, EXTERNAL,
                                             f"ai-regression.yml run {runs[0]['id']}")}
    return guarded(names, "ai-regression.yml", collect)


def measurements_artifact(client: develop_red.Client, repo: str, sha: str,
                          dest: str) -> tuple[Metrics | None, str]:
    """(metrics, where) of the code-quality-measurements artifact at that SHA, or (None, why not)."""
    try:
        found = newest_artifact(client, f"{OWNER}/{repo}", MEASUREMENTS,
                                lambda run: run.get("head_sha") == sha)
        if found is None:
            return None, f"no run at {sha[:12]} carries {MEASUREMENTS}"
        doc = read_json(download(client, f"{OWNER}/{repo}", found, dest), "measurements.json")
        if not isinstance(doc.get("metrics"), dict):
            return None, f"{MEASUREMENTS} at {sha[:12]} has no metrics table"
        return doc["metrics"], f"{MEASUREMENTS} artifact of run {found['workflow_run']['id']}"
    except (NotCollected, Failed) as exc:
        return None, str(exc)


def previous_record(client: develop_red.Client, dest: str) -> tuple[str | None, str]:
    """(path, where) of the newest successful develop fleet-health.yml record other than this run's."""
    current = os.environ.get("GITHUB_RUN_ID", "")

    def keep(run: dict[str, Any]) -> bool:
        if not on_develop(run) or str(run.get("id")) == current:
            return False
        return get(client, f"/repos/{OWNER}/{HUB}/actions/runs/{run['id']}").get("conclusion") == "success"
    try:
        found = newest_artifact(client, f"{OWNER}/{HUB}", RECORD, keep)
    except NotCollected as exc:
        return None, f"none ({exc})"
    if found is None:
        return None, f"none (no successful {WORKFLOW} run carries {RECORD} yet)"
    directory = download(client, f"{OWNER}/{HUB}", found, dest)
    names = sorted(f for f in os.listdir(directory) if f.endswith(".json"))
    if len(names) != 1:
        raise Failed(f"{RECORD} of run {found['workflow_run']['id']} holds {len(names)} JSON files")
    return os.path.join(directory, names[0]), f"{RECORD} of run {found['workflow_run']['id']}"


def issue_body(record: dict[str, Any], run_url: str) -> str:
    """The fleet-health issue text: every regressed metric of one record."""
    lines = [f"The weekly fleet health ({record['date']}) regressed against {record['baseline']}:", ""]
    lines += [f"- `{r['repo']}/{r['metric']}`: {r['before']} -> {r['now']}" for r in record["regressed"]]
    lines += ["", f"Run: {run_url}" if run_url else "Run: local",
              "", "Closes itself after the next run without a regression; see docs/fleet-health.md."]
    return "\n".join(lines)


def ensure_label(client: develop_red.Client) -> None:
    """Create the fleet-health label once; issues are filed under it and never under develop-red."""
    try:
        client.call("GET", f"/repos/{OWNER}/{HUB}/labels/{ISSUE_LABEL}")
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        client.call("POST", f"/repos/{OWNER}/{HUB}/labels",
                    {"name": ISSUE_LABEL, "color": "d93f0b",
                     "description": "A code metric regressed in the weekly fleet health"})


def sync_issue(client: develop_red.Client, record: dict[str, Any], run_url: str) -> str:
    """Open or update exactly one fleet-health issue on a regression, close it after a run without one."""
    path = f"/repos/{OWNER}/{HUB}/issues"
    found = [i for i in client.call("GET", f"{path}?labels={ISSUE_LABEL}&state=open&per_page={PAGE}")
             if "pull_request" not in i]
    found.sort(key=lambda i: i["number"])
    if record["verdict"] == "regressed":
        title = f"fleet-health: {len(record['regressed'])} code metric(s) regressed"
        text = issue_body(record, run_url)
        for extra in found[1:]:
            client.call("PATCH", f"{path}/{extra['number']}", {"state": "closed", "state_reason": "not_planned"})
        if found:
            client.call("PATCH", f"{path}/{found[0]['number']}", {"title": title, "body": text})
            return f"updated #{found[0]['number']}"
        ensure_label(client)
        client.call("POST", path, {"title": title, "body": text, "labels": [ISSUE_LABEL]})
        return "opened"
    if record["verdict"] != "ok":
        return f"left alone: verdict {record['verdict']}"
    for issue in found:
        client.call("POST", f"{path}/{issue['number']}/comments",
                    {"body": f"No code metric regressed in {run_url or 'a local run'}."})
        client.call("PATCH", f"{path}/{issue['number']}", {"state": "closed", "state_reason": "completed"})
    return f"closed {len(found)}"
