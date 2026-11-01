#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Weekly health of the AI repos: their quality-report tree metrics plus GitHub state, graded against a baseline.
It does not attribute a regression to a commit, rerun lanes or grade external metrics; see docs/fleet-health.md#grades-and-verdict"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import shutil
import subprocess
import sys
import tempfile
from typing import Any

import develop_red
import fleet_health_github as gh
import fleet_health_tree as tree
from quality_report_compare import movement, shown
from quality_report_model import Metric

HUB = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_REPOS = "AccelerANTgine,OxidANT,OrchestrANT,OmniAccelerANT"
SCHEMA_VERSION = 1
KIND = "fleet-health"
FLEET = "fleet"
EXIT = {"ok": 0, "regressed": 1, "incomplete": 2}
UNGRADED = frozenset({gh.EXTERNAL, gh.REPORT})


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(prog="fleet-health.py", description=__doc__)
    ap.add_argument("--repos", default=DEFAULT_REPOS, help=f"comma list (default: {DEFAULT_REPOS})")
    where = ap.add_mutually_exclusive_group()
    where.add_argument("--local-root", metavar="DIR", help="measure the checkouts DIR/<repo> as they are")
    where.add_argument("--clone", action="store_true", help="clone each develop tip and measure that")
    ap.add_argument("--compare", metavar="JSON|previous-run",
                    help="a fleet-health record, or the newest successful fleet-health.yml artifact")
    ap.add_argument("--out", default=os.path.join(HUB, "logs", "reports", "fleet-health"),
                    help="where <date>.json and <date>.md go")
    ap.add_argument("--work", help="scratch directory for clones and artifacts (default: a temporary one)")
    ap.add_argument("--clone-url", default=tree.CLONE_URL, help="clone URL with {repo} (default: GitHub)")
    ap.add_argument("--sync-issue", metavar="JSON", help="open, update or close the fleet-health issue for a record")
    ap.add_argument("--replay", help="JSON file mapping each GET path to its answer (tests)")
    ap.add_argument("--now", help="the current time as YYYY-MM-DDTHH:MM:SSZ (tests)")
    args = ap.parse_args(argv)
    if not args.sync_issue and not (args.local_root or args.clone):
        ap.error("one of --local-root DIR or --clone is required")
    return args


def gh_token() -> str:
    """GH_TOKEN, GITHUB_TOKEN or the GitHub CLI's login; empty when none is there."""
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    if token or not shutil.which("gh"):
        return token
    out = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, check=False,
                         stdin=subprocess.DEVNULL)
    return out.stdout.strip() if out.returncode == 0 else ""


def load_record(path: str) -> dict[str, Any]:
    """A previous fleet-health record; a malformed one raises ValueError or TypeError."""
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"compare file {path} is unreadable: {exc}") from None
    if not isinstance(doc, dict) or doc.get("kind") != KIND or doc.get("schema_version") != SCHEMA_VERSION:
        raise TypeError(f"compare file {path} is not a schema_version {SCHEMA_VERSION} {KIND} record")
    if not isinstance(doc.get("repos"), dict):
        raise TypeError(f"compare file {path} has no repos table")
    return doc


def baseline(args: argparse.Namespace, client: develop_red.Client, work: str,
             problems: list[str]) -> tuple[dict[str, Any], str]:
    """(repos table, description) of the comparison; a first run compares with nothing."""
    if not args.compare:
        return {}, "none (no --compare given)"
    path, where = args.compare, args.compare
    try:
        if args.compare == "previous-run":
            found, where = gh.previous_record(client, os.path.join(work, "baseline"))
            if found is None:
                return {}, where
            path = found
        return load_record(path)["repos"], where
    except (ValueError, TypeError, gh.Failed, gh.NotCollected) as exc:
        problems.append(str(exc))
        return {}, f"none ({exc})"


def measure_repo(co: tree.Checkout, clients: dict[str, Any], work: str,
                 now: dt.datetime) -> dict[str, Any]:
    """One repository's record: tree metrics from its checkout, artifact and external metrics from GitHub."""
    general, alerts, token, cache = clients["general"], clients["alerts"], clients["token"], clients["cache"]
    entry: dict[str, Any] = {"sha": co.sha, "checkout": co.path, "quality_report": "", "metrics": {}}
    if co.error:
        entry["metrics"]["checkout"] = gh.gap(gh.FAILED, "", gh.LOWER, gh.CODE, "checkout", co.error)
        return entry
    metrics, entry["quality_report"] = tree.tree_metrics(co)
    conf = tree.config(co)
    names = tree.artifact_names(conf, list(metrics))
    if names:
        lane, where = gh.measurements_artifact(general, co.repo, co.sha, os.path.join(work, "lane"))
        metrics = tree.overlay(metrics, names, lane, where)
    metrics.update(gh.ci_runs(general, co.repo))
    metrics.update(gh.dependabot(alerts, co.repo, token))
    metrics.update(gh.code_scanning(alerts, co.repo, token, co.exists, now))
    metrics.update(gh.secret_scanning(alerts, co.repo, token))
    metrics.update(gh.develop_red_issues(general, co.repo, cache))
    metrics.update(gh.hub_pin_lag(general, tree.hub_pin(co)))
    metrics.update(gh.security_audit(general, co.repo, os.path.join(work, "audit")))
    metrics.update(gh.bench_history(general, co.repo, tree.benchmark_keys(conf), os.path.join(work, "bench")))
    metrics.update(gh.ai_regression(general, co.repo))
    entry["metrics"] = metrics
    return entry


def grade(now: dict[str, Any], before: dict[str, Any] | None) -> str:
    """improved, held, regressed, moved (external and report rows), new (no baseline value) or not-collected."""
    if now.get("status") != gh.COLLECTED:
        return now.get("status", gh.NOT_COLLECTED)
    if now.get("class") in UNGRADED:
        return "moved"
    old = (before or {}).get("value")
    if (before or {}).get("status") != gh.COLLECTED or not isinstance(old, (int, float)):
        return "new"
    metric = Metric("", float(now["value"]), now.get("unit", ""), now.get("better", gh.LOWER),
                    now.get("class", gh.CODE), "", members=now.get("members"))
    change = movement(metric, float(old), (before or {}).get("members"))
    if isinstance(change, list) or change > 0:
        return "regressed"
    return "improved" if change < 0 else "held"


def grade_all(repos: dict[str, Any], before: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    """Grade every metric in place; returns the rows per grade."""
    rows: dict[str, list[dict[str, Any]]] = {}
    for repo, entry in sorted(repos.items()):
        old_metrics = (before.get(repo) or {}).get("metrics") or {}
        for name, row in sorted(entry["metrics"].items()):
            old = old_metrics.get(name)
            row["grade"] = grade(row, old)
            if isinstance(old, dict) and old.get("status") == gh.COLLECTED:
                row["before"] = old.get("value")
            rows.setdefault(row["grade"], []).append(
                {"repo": repo, "metric": name, "before": shown(row.get("before", "-")),
                 "now": shown(row["value"]) if row["value"] is not None else row["status"],
                 "reason": row.get("reason", "")})
    return rows


def markdown(record: dict[str, Any], line: str) -> str:
    """The step-summary page: verdict, regressions, improvements, gaps and every metric."""
    out = [f"### {line}", "", f"Baseline: {record['baseline']}", ""]
    for title, key in (("Regressed", "regressed"), ("Improved", "improved")):
        if record[key]:
            out += [f"#### {title}", "", "| repo | metric | before | now |", "| --- | --- | --- | --- |"]
            out += [f"| {r['repo']} | {r['metric']} | {r['before']} | {r['now']} |" for r in record[key]]
            out.append("")
    gaps = record["not_collected"] + record["failed"]
    if gaps or record["problems"]:
        out += ["#### Not collected or failed", ""]
        out += [f"- {r['repo']}/{r['metric']}: {r['now']} ({r['reason']})" for r in gaps]
        out += [f"- problem: {p}" for p in record["problems"]] + [""]
    for repo, entry in sorted(record["repos"].items()):
        out += [f"#### {repo} @ {entry.get('sha', '')[:12] or '-'}", "",
                "| metric | before | now | grade |", "| --- | --- | --- | --- |"]
        out += [f"| {name} | {shown(row.get('before', '-'))} | "
                f"{shown(row['value']) if row['value'] is not None else row['status']} | {row['grade']} |"
                for name, row in sorted(entry["metrics"].items())]
        out.append("")
    return "\n".join(out)


def clients_for(args: argparse.Namespace) -> dict[str, Any]:
    """The reading clients: alerts use FLEET_HEALTH_TOKEN when set, everything else the general token."""
    replay = None
    if args.replay:
        with open(args.replay, encoding="utf-8") as fh:
            replay = json.load(fh)
    general = gh_token()
    token = os.environ.get("FLEET_HEALTH_TOKEN") or general
    return {"general": develop_red.Client(general, True, replay),
            "alerts": develop_red.Client(token, True, replay), "token": token, "cache": {}}


def checkouts_for(args: argparse.Namespace, repos: list[str], work: str) -> dict[str, tree.Checkout]:
    if args.clone:
        return {r: tree.clone_checkout(os.path.join(work, "clones"), r, args.clone_url) for r in repos}
    return {r: tree.local_checkout(os.path.abspath(args.local_root), r) for r in repos}


def report(record: dict[str, Any], line: str) -> None:
    print(line)
    print(f"compare: {record['baseline']}")
    for r in record["regressed"]:
        print(f"REGRESSED {r['repo']}/{r['metric']} {r['before']} -> {r['now']}")
    for r in record["not_collected"]:
        print(f"not-collected: {r['repo']}/{r['metric']} ({r['reason']})")
    for r in record["failed"]:
        print(f"failed: {r['repo']}/{r['metric']} ({r['reason']})")
    for problem in record["problems"]:
        print(f"problem: {problem}")


def run(args: argparse.Namespace, work: str) -> int:
    now = (dt.datetime.strptime(args.now, develop_red.ISO).replace(tzinfo=dt.UTC)
           if args.now else dt.datetime.now(dt.UTC))
    clients, problems = clients_for(args), []
    before, where = baseline(args, clients["general"], work, problems)
    repos = [r.strip() for r in args.repos.split(",") if r.strip()]
    checkouts = checkouts_for(args, repos, work)
    table = {r: measure_repo(co, clients, work, now) for r, co in checkouts.items()}
    table[FLEET] = {"sha": "", "checkout": "", "quality_report": "", "metrics": tree.shared_facts(checkouts)}
    rows = grade_all(table, before)
    verdict = ("incomplete" if problems or rows.get(gh.FAILED) else
               "regressed" if rows.get("regressed") else "ok")
    collected = sum(m["status"] == gh.COLLECTED for e in table.values() for m in e["metrics"].values())
    line = (f"fleet-health: verdict={verdict} regressed={len(rows.get('regressed', []))} "
            f"improved={len(rows.get('improved', []))} metrics={collected}")
    record = {"schema_version": SCHEMA_VERSION, "kind": KIND, "date": now.date().isoformat(),
              "generated_at": now.strftime(develop_red.ISO), "mode": "clone" if args.clone else "local-root",
              "hub_sha": tree.git(HUB, "rev-parse", "HEAD").stdout.strip(), "baseline": where,
              "verdict": verdict, "problems": problems, "repos": table,
              "regressed": rows.get("regressed", []), "improved": rows.get("improved", []),
              "not_collected": rows.get(gh.NOT_COLLECTED, []), "failed": rows.get(gh.FAILED, [])}
    os.makedirs(args.out, exist_ok=True)
    base = os.path.join(args.out, record["date"])
    with open(base + ".json", "w", encoding="utf-8") as fh:
        fh.write(json.dumps(record, indent=2, sort_keys=True) + "\n")
    with open(base + ".md", "w", encoding="utf-8") as fh:
        fh.write(markdown(record, line))
    report(record, line)
    print(f"wrote: {base}.json {base}.md")
    return EXIT[verdict]


def sync(args: argparse.Namespace) -> int:
    """The workflow's issue step: it writes with GITHUB_TOKEN, never with the read-only alerts token."""
    record = load_record(args.sync_issue)
    replay = None
    if args.replay:
        with open(args.replay, encoding="utf-8") as fh:
            replay = json.load(fh)
    client = develop_red.Client(os.environ.get("GITHUB_TOKEN", ""), False, replay)
    server, repo, run_id = (os.environ.get(k, "") for k in ("GITHUB_SERVER_URL", "GITHUB_REPOSITORY", "GITHUB_RUN_ID"))
    url = f"{server}/{repo}/actions/runs/{run_id}" if run_id else ""
    print(f"fleet-health issue: {gh.sync_issue(client, record, url)}")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.sync_issue:
        return sync(args)
    if args.work:
        os.makedirs(args.work, exist_ok=True)
        return run(args, args.work)
    with tempfile.TemporaryDirectory(prefix="fleet-health-") as work:
        return run(args, work)


if __name__ == "__main__":
    sys.exit(main())
