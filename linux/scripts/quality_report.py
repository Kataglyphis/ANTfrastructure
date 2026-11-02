#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""One measurement record, queue and verdict per checkout; run through quality-report.sh.
It reads lane outputs but runs no tests or builds; see docs/code-quality-tooling.md#quality-report"""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import tomllib

import quality_report_artifacts as artifacts
import quality_report_compare as compare
import quality_report_github as github
import quality_report_perf as perf
import quality_report_text as text
import quality_report_tree as tree
from quality_report_model import COLLECTED, SCHEMA_VERSION, Metric, git

HUB = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXIT = {"ok": 0, "regressed": 1, "incomplete": 2}


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """The command line of quality-report.sh."""
    ap = argparse.ArgumentParser(prog="quality-report.sh", description=__doc__)
    ap.add_argument("--root", default=".", help="the Git checkout to measure (default: .)")
    ap.add_argument("--compare", metavar="FILE|previous-develop",
                    help="a previous measurements.json, or the newest successful develop artifact")
    ap.add_argument("--hub", default=HUB,
                    help="the hub checkout hub-reuse compares with (default: the hub holding this script)")
    ap.add_argument("--offline", action="store_true",
                    help="read only local files: lane artifacts and previous-develop are not fetched")
    ap.add_argument("--perf-host", action="store_true",
                    help="run the declared [[perf.command]] latencies in the CI image instead; "
                         "compare with perf/baseline-<cpu>.json")
    ap.add_argument("--update-baseline", action="store_true",
                    help="with --perf-host: rewrite perf/baseline-<cpu>.json; refuses a spread above 5 %%")
    args = ap.parse_args(argv)
    if args.update_baseline and not args.perf_host:
        ap.error("--update-baseline needs --perf-host")
    return args


def load_config(root: str) -> tuple[dict[str, object], list[str]]:
    """quality-report.toml, or empty declarations when the repo has none; malformed is a problem."""
    path = os.path.join(root, "quality-report.toml")
    if not os.path.isfile(path):
        return {}, []
    try:
        with open(path, "rb") as fh:
            config = tomllib.load(fh)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        return {}, [f"quality-report.toml is malformed: {exc}"]
    if config.get("schema_version", 1) != 1:
        return {}, ["quality-report.toml schema_version must be 1"]
    return config, []


def tool_versions(root: str) -> dict[str, str]:
    """The tools behind the numbers, recorded so a pin move explains a moved count."""
    versions = {"python": platform.python_version(), "git": git(root, "--version")}
    venv = os.path.join(root, "logs/code-quality/python-static/.venv/bin")
    for name, exe in (("ruff", os.path.join(venv, "ruff")), ("ty", os.path.join(venv, "ty")),
                      ("pwsh", shutil.which("pwsh") or "")):
        if exe and os.access(exe, os.X_OK):
            out = subprocess.run([exe, "--version"], capture_output=True, text=True, check=False)
            versions[name] = out.stdout.strip()
    return versions


def collect(ctx: tree.Context, fetch: artifacts.Fetch) -> list[Metric]:
    """Every tree and artifact metric, in a stable order."""
    metrics = tree.scanners(ctx) + tree.python_static(ctx) + [tree.powershell(ctx)]
    metrics += text.allow_rows(ctx) + text.suppressions(ctx) + text.doc_lengths(ctx)
    metrics += [text.agents_drift(ctx)] + text.declared(ctx)
    return metrics + artifacts.collect(ctx.config, fetch)


def baseline(args: argparse.Namespace, fetch: artifacts.Fetch,
             problems: list[str]) -> tuple[dict[str, dict[str, object]] | None, str]:
    """(metrics table, description) of the comparison baseline, or (None, why there is none)."""
    if not args.compare:
        return None, "none (no --compare given)"
    path, where = args.compare, args.compare
    if args.compare == "previous-develop":
        try:
            if args.offline or fetch.slug is None:
                raise github.Unavailable("--offline or no GitHub origin")
            path, where = github.previous_develop(fetch.slug, os.path.join(fetch.work, "baseline"))
        except github.Unavailable as exc:
            return None, f"none ({exc})"
        except github.Broken as exc:
            problems.append(str(exc))
            return None, f"none ({exc})"
    try:
        return compare.load_baseline(path), where
    except ValueError as exc:
        problems.append(str(exc))
        return None, f"none ({exc})"


def write(out: str, name: str, body: str) -> None:
    """One output file under logs/code-quality/."""
    with open(os.path.join(out, name), "w", encoding="utf-8") as fh:
        fh.write(body)


def main(argv: list[str] | None = None) -> int:
    """Measure, compare, write measurements.json and queue.md, print the verdict."""
    args = parse_args(argv)
    root = git(os.path.abspath(args.root), "rev-parse", "--show-toplevel")
    if not root:
        print(f"quality-report: --root {args.root} is not a Git checkout", file=sys.stderr)
        return 2
    out = os.path.join(root, "logs", "code-quality")
    work = os.path.join(out, "quality-report")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    config, problems = load_config(root)
    if args.perf_host:
        if problems:
            return perf.report([], perf.Graded(problems=problems), "none")
        return perf.run(root, os.path.abspath(args.hub), config, args.update_baseline)
    ctx = tree.Context(root, os.path.abspath(args.hub), work, config)
    problems += text.docs_build_list(ctx)
    sha = git(root, "rev-parse", "HEAD")
    fetch = artifacts.Fetch(root, work, github.repo_slug(root), sha, args.offline)
    metrics = collect(ctx, fetch)
    before, where = baseline(args, fetch, problems)
    result = compare.grade(metrics, before)
    result.problems = problems + result.problems
    verdict = result.verdict(metrics)
    line = (f"quality-report: verdict={verdict} regressed={len(result.regressed)} "
            f"improved={len(result.improved)} "
            f"metrics={sum(m.status == COLLECTED for m in metrics)}")
    record = {"schema_version": SCHEMA_VERSION, "repo": fetch.slug or os.path.basename(root),
              "sha": sha, "dirty": bool(git(root, "status", "--porcelain", "--untracked-files=no")),
              "hub_sha": git(ctx.hub, "rev-parse", "HEAD"), "tools": tool_versions(root),
              "declared": text.declared_outputs(config), "baseline": where,
              "verdict": verdict, "problems": result.problems,
              "metrics": {m.name: m.record() for m in metrics}}
    write(out, "measurements.json", json.dumps(record, indent=2, sort_keys=True) + "\n")
    write(out, "queue.md", compare.queue(metrics, f"{record['repo']} @ {sha[:12]}"))
    write(out, "summary.md", compare.summary(metrics, result, line, where))
    print(line)
    print(f"compare: {where}")
    for name, old, new in result.regressed:
        print(f"REGRESSED {name} {old} -> {new}")
    for metric in metrics:
        if metric.status != COLLECTED:
            print(f"not-collected: {metric.name} ({metric.reason})")
    for problem in result.problems:
        print(f"problem: {problem}")
    return EXIT[verdict]


if __name__ == "__main__":
    sys.exit(main())
