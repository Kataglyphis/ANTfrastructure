#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Benchmark results against the median of earlier default-branch results; a gated metric that doubles fails.
It does not judge noise below a doubling, compare across runners or arches, or prove a stored result came from a green run; see docs/code-quality-tooling.md#benchmark-history"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import statistics
import sys
from collections.abc import Callable
from fnmatch import fnmatchcase
from typing import Any, NamedTuple

SCHEMA_VERSION = 1
FORMATS = ("criterion", "google-benchmark", "flutter-frame", "orchestrant-bench")
# Fewer earlier results than this only warn, so one odd runner cannot become the yardstick.
MIN_HISTORY_TO_FAIL = 3
FAIL_RATIO = 2.0
ARTIFACT_PREFIX = "bench-history-"
EXIT_INPUT = 2
GBENCH_UNITS = {"ns": 1.0, "us": 1e3, "ms": 1e6, "s": 1e9}
GBENCH_FIELDS = {
    "name", "family_index", "per_family_instance_index", "run_name", "run_type", "repetitions",
    "repetition_index", "threads", "iterations", "real_time", "cpu_time", "time_unit",
    "aggregate_name", "aggregate_unit", "error_occurred", "error_message", "label",
}  # fmt: skip


# A metric's value and its unit: ns, ms, or empty for a count or rate.
Measure = tuple[float, str]


class InputError(Exception):
    """A result file is missing, empty or unreadable."""


class Rule(NamedTuple):
    """A caller's declaration for the metrics its pattern matches."""

    direction: str
    gate: bool


def is_number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def read_json(path: pathlib.Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise InputError(f"{path}: {exc}") from None


def read_criterion(path: pathlib.Path) -> dict[str, Measure]:
    """Benchmark name -> mean in ns, from each `<bench>/new/estimates.json` Criterion wrote."""
    means: dict[str, Measure] = {}
    for new in sorted(path.glob("**/new/estimates.json")):
        mean = read_json(new).get("mean", {}).get("point_estimate")
        if is_number(mean):
            means[str(new.parent.parent.relative_to(path))] = (mean, "ns")
    return means


def _gbench_rows(doc: dict[str, Any]) -> list[dict[str, Any]]:
    rows = [r for r in doc.get("benchmarks", []) if isinstance(r, dict) and not r.get("error_occurred")]
    medians = [r for r in rows if r.get("run_type") == "aggregate" and r.get("aggregate_name") == "median"]
    if medians:
        return medians
    return [r for r in rows if r.get("run_type", "iteration") == "iteration"]


def parse_google_benchmark(doc: object) -> dict[str, Measure]:
    """`<name>` -> real time in ns, `<name>/<counter>` -> each user counter; repetitions use their median."""
    if not isinstance(doc, dict) or not isinstance(doc.get("benchmarks"), list):
        return {}
    values: dict[str, Measure] = {}
    for row in _gbench_rows(doc):
        name = str(row.get("run_name") or row.get("name"))
        scale = GBENCH_UNITS.get(str(row.get("time_unit", "ns")))
        if scale is not None and is_number(row.get("real_time")):
            values[name] = (row["real_time"] * scale, "ns")
        for counter, value in row.items():
            if counter not in GBENCH_FIELDS and is_number(value):
                values[f"{name}/{counter}"] = (value, "")
    return values


def parse_flutter_frame(doc: object) -> dict[str, Measure]:
    """`<scenario>/<summary key>` -> value, from integration_test/performance_test.dart's timings."""
    if not isinstance(doc, dict):
        return {}
    return {f"{scenario}/{key}": (value, "")
            for scenario, summary in doc.items() if isinstance(summary, dict)
            for key, value in summary.items() if is_number(value)}


def parse_orchestrant_bench(doc: object) -> dict[str, Measure]:
    """`<label>/p50_ms` and `<label>/p95_ms` of each report row of an orchestrant-bench envelope."""
    if not isinstance(doc, dict) or not isinstance(doc.get("reports"), list):
        return {}
    return {f"{row['label']}/{key}": (row[key], "ms")
            for row in doc["reports"] if isinstance(row, dict) and "label" in row
            for key in ("p50_ms", "p95_ms") if is_number(row.get(key))}


PARSERS: dict[str, Callable[[object], dict[str, Measure]]] = {
    "google-benchmark": parse_google_benchmark,
    "flutter-frame": parse_flutter_frame,
    "orchestrant-bench": parse_orchestrant_bench,
}


def read_result(fmt: str, path: pathlib.Path) -> dict[str, Measure]:
    """This run's metrics; a missing, empty or metric-free result is an InputError."""
    if fmt == "criterion":
        if not path.is_dir():
            raise InputError(f"No benchmark results under {path}")
        values = read_criterion(path)
    else:
        if not path.is_file() or path.stat().st_size == 0:
            raise InputError(f"{path}: missing or empty")
        values = PARSERS[fmt](read_json(path))
    if not values:
        raise InputError(f"No benchmark results under {path}")
    return values


def history_metrics(fmt: str, doc: object) -> dict[str, float]:
    """One earlier result: a stored record, a raw result of the format, or a flat name -> value map."""
    if not isinstance(doc, dict):
        return {}
    if doc.get("schema_version") == SCHEMA_VERSION and isinstance(doc.get("metrics"), dict):
        if doc.get("verdict", "ok") != "ok":
            return {}
        doc = doc["metrics"]
    parsed = {name: value for name, (value, _) in PARSERS[fmt](doc).items()} if fmt in PARSERS else {}
    return parsed or {k: v for k, v in doc.items() if is_number(v)}


def read_history(fmt: str, path: pathlib.Path) -> list[dict[str, float]]:
    """Earlier results: every *.json in a directory, or one file; an unreadable one is an InputError."""
    files = sorted(path.glob("*.json")) if path.is_dir() else [path] if path.is_file() else []
    runs = [history_metrics(fmt, read_json(f)) for f in files]
    return [r for r in runs if r]


def parse_rules(text: str) -> list[tuple[str, Rule]]:
    """`{"<glob>": {"direction": "lower"|"higher", "gate": true}}`, in declaration order."""
    try:
        doc = json.loads(text or "{}")
    except json.JSONDecodeError as exc:
        raise InputError(f"--metrics is not JSON: {exc}") from None
    if not isinstance(doc, dict):
        raise InputError("--metrics must be a JSON object of metric globs")
    rules = []
    for pattern, spec in doc.items():
        if not isinstance(spec, dict) or spec.get("direction") not in ("lower", "higher"):
            raise InputError(f"--metrics {pattern!r}: direction must be lower or higher")
        if not isinstance(spec.get("gate", False), bool):
            raise InputError(f"--metrics {pattern!r}: gate must be true or false")
        rules.append((pattern, Rule(spec["direction"], spec.get("gate", False))))
    return rules


def rule_for(name: str, rules: list[tuple[str, Rule]]) -> Rule | None:
    """An exact declaration wins, then the first glob that matches; undeclared metrics are never judged."""
    exact = [rule for pattern, rule in rules if pattern == name]
    if exact:
        return exact[0]
    return next((rule for pattern, rule in rules if fnmatchcase(name, pattern)), None)


def readable(unit: str, value: float) -> str:
    if unit == "ns" and value >= 0:
        return f"{value / 1e6:.2f} ms" if value >= 1e5 else f"{value / 1e3:.2f} µs"
    if unit == "ms":
        return f"{value:.2f} ms"
    return f"{value:.1f}" if isinstance(value, float) else str(value)


def doubled(rule: Rule, ratio: float) -> bool:
    return ratio >= FAIL_RATIO if rule.direction == "lower" else ratio <= 1 / FAIL_RATIO


def slipped(rule: Rule, ratio: float, warn: float) -> bool:
    return ratio - 1 > warn if rule.direction == "lower" else 1 - ratio > warn


def judge(unit: str, name: str, value: float, earlier: list[float], rule: Rule | None,
          warn: float) -> tuple[str, str | None]:
    """The row's change cell, and a failure message for a gated metric that doubled."""
    if not earlier:
        return "no history yet", None
    median = statistics.median(earlier)
    cell = f"(median {readable(unit, median)} of {len(earlier)})"
    if median == 0:
        return cell, None
    ratio = value / median
    change = f"{(ratio - 1) * 100:+.1f} %"
    cell = f"{change} {cell}"
    if rule is None:
        return cell, None
    title = "slower" if rule.direction == "lower" else "worse"
    against = f"{name} {change} against the median of {len(earlier)} runs"
    if rule.gate and doubled(rule, ratio):
        if len(earlier) >= MIN_HISTORY_TO_FAIL:
            print(f"::error title=Benchmark far {title}::{against}", file=sys.stderr)
            return cell, f"{name} {change}"
        print(f"::warning title=Benchmark history short::{name}: {len(earlier)} earlier "
              f"result(s), a doubling fails from {MIN_HISTORY_TO_FAIL}", file=sys.stderr)
    if slipped(rule, ratio, warn):
        print(f"::warning title=Benchmark {title}::{against}", file=sys.stderr)
    return cell, None


def write_record(path: str, args: argparse.Namespace, verdict: str, values: dict[str, float]) -> None:
    record = {
        "schema_version": SCHEMA_VERSION, "key": args.key, "format": args.format,
        "sha": os.environ.get("GITHUB_SHA", ""), "run_id": os.environ.get("GITHUB_RUN_ID", ""),
        "verdict": verdict, "metrics": values,
    }
    target = pathlib.Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def report(args: argparse.Namespace) -> int:
    """Print the Markdown table; 1 when a gated metric doubled against enough history."""
    rules = parse_rules(args.metrics)
    values = read_result(args.format, pathlib.Path(args.result))
    runs = read_history(args.format, pathlib.Path(args.history)) if args.history else []
    column = {"criterion": "Mean", "google-benchmark": "Time"}.get(args.format, "Value")
    print(f"| Benchmark | {column} | Change against earlier runs |")
    print("| --- | --- | --- |")
    failed: dict[str, list[str]] = {"lower": [], "higher": []}
    for name, (value, unit) in values.items():
        earlier = [r[name] for r in runs if is_number(r.get(name))]
        rule = rule_for(name, rules)
        cell, failure = judge(unit, name, value, earlier, rule, args.warn)
        print(f"| `{name}` | {readable(unit, value)} | {cell} |")
        if failure and rule:
            failed[rule.direction].append(failure)
    for direction, label in (("lower", "Far slower"), ("higher", "Far lower")):
        if failed[direction]:
            print(f"\n{label} than before: {', '.join(failed[direction])}.")
    verdict = "failed" if any(failed.values()) else "ok"
    if args.write:
        write_record(args.write, args, verdict, {name: value for name, (value, _) in values.items()})
    return 1 if verdict == "failed" else 0


def _candidates(slug: str, key: str, branch: str, pages: int) -> list[dict[str, Any]]:
    """Unexpired bench-history-<key> artifacts of earlier default-branch runs, newest first, one per run."""
    import quality_report_github as github
    current = os.environ.get("GITHUB_RUN_ID", "")
    seen: dict[str, dict[str, Any]] = {}
    for page in range(1, pages + 1):
        doc = github.api(f"repos/{slug}/actions/artifacts?name={ARTIFACT_PREFIX}{key}&per_page=100&page={page}")
        rows = doc.get("artifacts")
        if not isinstance(rows, list):
            raise github.Broken("GitHub answer has no `artifacts` list")
        for row in rows:
            run = row.get("workflow_run") if isinstance(row, dict) else None
            if not isinstance(run, dict) or row.get("expired") or row.get("name") != f"{ARTIFACT_PREFIX}{key}":
                continue
            run_id = str(run.get("id", ""))
            newer = str(seen.get(run_id, {}).get("created_at", "")) <= str(row.get("created_at", ""))
            if run.get("head_branch") == branch and run_id not in ("", current) and newer:
                seen[run_id] = row
        if len(rows) < 100:
            break
    return sorted(seen.values(), key=lambda a: str(a.get("created_at", "")), reverse=True)


def _download(slug: str, key: str, artifact: dict[str, Any], dest: pathlib.Path) -> pathlib.Path:
    """One earlier record into dest as <created>-<run>.json."""
    import shutil
    import tempfile

    import quality_report_github as github
    run_id = int(str(artifact["workflow_run"]["id"]))
    with tempfile.TemporaryDirectory() as tmp:
        github.download(slug, run_id, f"{ARTIFACT_PREFIX}{key}", tmp)
        found = sorted(pathlib.Path(tmp).glob("**/*.json"))
        if len(found) != 1:
            raise github.Broken(f"run {run_id}'s {ARTIFACT_PREFIX}{key} holds {len(found)} JSON files, not 1")
        target = dest / f"{str(artifact.get('created_at', '')).replace(':', '')}-{run_id}.json"
        shutil.copyfile(found[0], target)
    return target


def fetch(args: argparse.Namespace) -> int:
    """Download up to --keep earlier default-branch records through the Actions API."""
    from concurrent.futures import ThreadPoolExecutor

    import quality_report_github as github
    slug = args.repo or github.repo_slug(".")
    if not slug:
        raise github.Unavailable("no repository: pass --repo or set GITHUB_REPOSITORY")
    branch = args.branch or str(github.api(f"repos/{slug}").get("default_branch", ""))
    if not branch:
        raise github.Broken(f"repos/{slug} names no default branch")
    dest = pathlib.Path(args.dest)
    dest.mkdir(parents=True, exist_ok=True)
    chosen = _candidates(slug, args.key, branch, args.pages)[: args.keep]
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(lambda a: _download(slug, args.key, a, dest), chosen))
    print(f"bench-history: read {len(chosen)} earlier result(s) of {ARTIFACT_PREFIX}{args.key} on {branch}")
    return 0


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    rep = sub.add_parser("report", help="print the table against earlier results")
    rep.add_argument("--format", required=True, choices=FORMATS)
    rep.add_argument("--result", required=True, help="the run's JSON file, or Criterion's output directory")
    rep.add_argument("--history", help="a directory of earlier results, or one file")
    rep.add_argument("--metrics", default="{}", help='JSON: {"<glob>": {"direction": "lower"|"higher", "gate": true}}')
    rep.add_argument("--warn", type=float, default=0.25, help="worse than the median by this fraction warns")
    rep.add_argument("--key", default="", help="the history key the record names")
    rep.add_argument("--write", metavar="FILE", help="also write this run's record, for the history")
    fet = sub.add_parser("fetch", help="download earlier default-branch records")
    fet.add_argument("--key", required=True)
    fet.add_argument("--dest", required=True)
    fet.add_argument("--keep", type=int, default=20)
    fet.add_argument("--branch", default="", help="default: the repository's default branch")
    fet.add_argument("--repo", default="", help="owner/name; default: GITHUB_REPOSITORY or origin")
    fet.add_argument("--pages", type=int, default=10, help="artifact list pages of 100 to scan")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.command == "fetch":
        # The Actions client and its thread pool load only here, keeping each report call quick.
        import quality_report_github as github

        try:
            return fetch(args)
        except (github.Unavailable, github.Broken) as exc:
            print(f"::error title=Benchmark history unreadable::{exc}", file=sys.stderr)
            return EXIT_INPUT
    try:
        return report(args)
    except InputError as exc:
        print(str(exc))
        print(f"::error title=Benchmark result missing::{exc}", file=sys.stderr)
        return EXIT_INPUT


if __name__ == "__main__":
    sys.exit(main())
