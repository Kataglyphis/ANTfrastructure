# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""quality-report.sh --perf-host: declared latency commands in the CI image against a per-CPU baseline.

It does not prove the commands time the right thing or that a quiet load average means a quiet host;
see docs/fleet-health.md#perf-host"""

from __future__ import annotations

import json
import os
import re
import statistics
import subprocess
from dataclasses import dataclass, field
from datetime import UTC, datetime

from quality_report_model import COLLECTED, FAILED, HIGHER, LOWER, NOT_COLLECTED, git

RUNS = 20
DEFAULT_CPUS = 8
MAX_LOAD = 2.0
MIN_LIMIT = 0.10
SPREAD_FACTOR = 3.0
MAX_BASELINE_SPREAD = 0.05
INSIDE_HUB = "/opt/kataglyphis-scripts"
INSIDE_ROOT = "/workspace"
OUT = "logs/code-quality/perf"


@dataclass
class PerfMetric:
    """One declared latency figure and its raw samples, one per run."""

    name: str
    unit: str
    better: str
    samples: list[float] = field(default_factory=list)
    status: str = COLLECTED
    reason: str = ""

    def median(self) -> float:
        """The figure that is graded: the median of the runs."""
        return statistics.median(self.samples)

    def spread(self) -> float:
        """Run-to-run spread: the median absolute deviation over the median."""
        mid = self.median()
        return statistics.median(abs(x - mid) for x in self.samples) / mid


def parse_plan(config: dict[str, object]) -> tuple[dict[str, object], list[PerfMetric], list[str]]:
    """(runner plan, declared metrics, problems) from quality-report.toml's [perf] table."""
    perf = config.get("perf")
    if not isinstance(perf, dict) or not perf.get("command"):
        return {}, [], ["quality-report.toml declares no [[perf.command]]"]
    commands, metrics, problems = [], [], []
    for command in perf["command"]:
        name, run, rows = command.get("name"), command.get("run"), command.get("metrics")
        if not (isinstance(name, str) and re.fullmatch(r"[a-z0-9_]+", name) and isinstance(run, str)
                and isinstance(rows, list) and rows):
            problems.append(f"[[perf.command]] {name!r} needs a snake_case name, a run string and metrics")
            continue
        keys = []
        for row in rows:
            if not isinstance(row, dict) or row.get("better") not in (LOWER, HIGHER) \
                    or not isinstance(row.get("key"), str) or not isinstance(row.get("unit"), str):
                problems.append(f"perf command {name}: each metric needs key, unit and better")
                continue
            keys.append(row["key"])
            metrics.append(PerfMetric(f"perf.{name}.{row['key']}", row["unit"], row["better"]))
        commands.append({"name": name, "run": run, "keys": keys})
    plan = {"cpus": int(perf.get("cpus", DEFAULT_CPUS)), "runs": RUNS,
            "setup": str(perf.get("setup", "")), "commands": commands}
    return plan, metrics, problems


def load_average() -> float:
    """The host's 1-minute load average."""
    return os.getloadavg()[0]


def chain_pidfile() -> str:
    """The pidfile an image chain claims while it runs."""
    return os.path.join(os.environ.get("TMPDIR") or "/tmp", "kata-cross-chain.pid")


def refusals(root: str) -> list[str]:
    """Why this host or checkout cannot give a comparable measurement now."""
    reasons = []
    if git(root, "status", "--porcelain"):
        reasons.append("the checkout is dirty; measure a commit")
    if (load := load_average()) > MAX_LOAD:
        reasons.append(f"1-minute load {load:.2f} is above {MAX_LOAD:g}")
    if os.path.exists(chain_pidfile()):
        reasons.append(f"an image chain is running ({chain_pidfile()} exists)")
    return reasons


def cpu_model() -> str:
    """lscpu's model name, the key of the baseline file."""
    out = subprocess.run(["lscpu"], capture_output=True, text=True, check=False,
                         env={**os.environ, "LC_ALL": "C"})
    for line in out.stdout.splitlines():
        key, _, value = line.partition(":")
        if key.strip() == "Model name" and value.strip():
            return value.strip()
    raise OSError("lscpu printed no model name")


def baseline_path(root: str, model: str) -> str:
    """perf/baseline-<cpu-slug>.json in the measured checkout."""
    slug = re.sub(r"[^a-z0-9]+", "-", model.lower()).strip("-")
    return os.path.join(root, "perf", f"baseline-{slug}.json")


def launch(root: str, hub: str, plan: dict[str, object]) -> dict[str, object]:
    """Run the plan in the CI image as the host user; the runner's samples document."""
    out = os.path.join(root, OUT)
    if os.path.exists(os.path.join(out, "samples.json")):
        os.remove(os.path.join(out, "samples.json"))
    with open(os.path.join(out, "plan.json"), "w", encoding="utf-8") as fh:
        json.dump(plan, fh, indent=2)
    inner = [f"python3 -I {INSIDE_HUB}/linux/scripts/quality_report_perf_run.py",
             f"--plan {INSIDE_ROOT}/{OUT}/plan.json --out {INSIDE_ROOT}/{OUT}/samples.json"]
    argv = ["bash", os.path.join(hub, "linux/scripts/run-in-ci-image.sh"), root, "--user", "0:0",
            "--mount-hub-scripts", "--", "bash", "-c", " ".join(inner)]
    with open(os.path.join(out, "container.log"), "w", encoding="utf-8") as log:
        done = subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT, check=False)
    if done.returncode != 0 or not os.path.isfile(os.path.join(out, "samples.json")):
        raise OSError(f"the image run exited {done.returncode}; see {OUT}/container.log")
    with open(os.path.join(out, "samples.json"), encoding="utf-8") as fh:
        return json.load(fh)


def fill(metrics: list[PerfMetric], samples: dict[str, object]) -> list[str]:
    """Copy the runner's samples into the declared metrics; returns problems."""
    if samples.get("setup_status", 0) != 0:
        for metric in metrics:
            metric.status, metric.reason = FAILED, f"setup exited {samples.get('setup_status')}"
        return [f"the [perf] setup failed ({samples.get('setup_status')}); see {OUT}/container.log"]
    commands = samples.get("commands")
    commands = commands if isinstance(commands, dict) else {}
    for metric in metrics:
        command, key = metric.name.split(".")[1:3]
        row = commands.get(command)
        if not isinstance(row, dict):
            metric.status, metric.reason = FAILED, "the runner reported nothing"
        elif row.get("status") != COLLECTED:
            metric.status, metric.reason = str(row.get("status")), str(row.get("reason"))
        else:
            metric.samples = list(row["samples"][key])
    return [f"{m.name}: {m.reason}" for m in metrics if m.status == FAILED]


@dataclass
class Graded:
    """The comparison of one run with the baseline."""

    regressed: list[str] = field(default_factory=list)
    improved: list[str] = field(default_factory=list)
    lines: list[str] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)


def grade_one(metric: PerfMetric, before: list[float], graded: Graded) -> None:
    """One metric against its baseline samples, beyond max(10 %, 3 x the baseline's spread)."""
    old = PerfMetric(metric.name, metric.unit, metric.better, before)
    limit = max(MIN_LIMIT, SPREAD_FACTOR * old.spread())
    ratio = metric.median() / old.median()
    worse = ratio > 1 + limit if metric.better == LOWER else ratio < 1 - limit
    better = ratio < 1 - limit if metric.better == LOWER else ratio > 1 + limit
    state = "regressed" if worse else "improved" if better else "held"
    graded.lines.append(f"ratio {metric.name} {ratio:.3f} {state} (baseline {old.median():.4g} now "
                        f"{metric.median():.4g} {metric.unit}, limit {limit:.1%})")
    if worse:
        graded.regressed.append(f"REGRESSED {metric.name} {old.median():.4g} -> {metric.median():.4g}")
    elif better:
        graded.improved.append(metric.name)


def grade(metrics: list[PerfMetric], baseline: dict[str, object] | None, where: str) -> Graded:
    """Every collected metric against the baseline; a metric it lacks is not graded."""
    graded = Graded()
    rows = baseline.get("metrics") if baseline else None
    for metric in metrics:
        if metric.status != COLLECTED or rows is None:
            continue
        before = rows.get(metric.name) if isinstance(rows, dict) else None
        samples = before.get("samples") if isinstance(before, dict) else None
        if not isinstance(samples, list) or not samples:
            metric.status, metric.reason = NOT_COLLECTED, f"absent from {where}"
            continue
        grade_one(metric, [float(x) for x in samples], graded)
    return graded


def read_baseline(path: str, model: str) -> tuple[dict[str, object] | None, list[str]]:
    """The tracked baseline for this CPU, or the problem that makes the verdict incomplete."""
    if not os.path.isfile(path):
        return None, [f"no baseline for {model!r}; record one with --update-baseline"]
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        return None, [f"{path} is unreadable: {exc}"]
    if not isinstance(data, dict) or data.get("cpu_model") != model \
            or not isinstance(data.get("metrics"), dict):
        return None, [f"{path} is not a baseline for {model!r}"]
    return data, []


def write_baseline(path: str, root: str, model: str, samples: dict[str, object],
                   metrics: list[PerfMetric]) -> None:
    """The tracked baseline: every run's raw sample per metric, plus where it was measured."""
    rows: dict[str, object] = {}
    for m in metrics:
        rows[m.name] = ({"unit": m.unit, "better": m.better, "samples": m.samples}
                        if m.status == COLLECTED else {"status": m.status, "reason": m.reason})
    record = {"schema_version": 1, "cpu_model": model, "sha": git(root, "rev-parse", "HEAD"),
              "recorded_at": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"), "runs": RUNS,
              "cpus": samples.get("cpus"), "metrics": rows}
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(record, fh, indent=2, sort_keys=True)
        fh.write("\n")


def report(metrics: list[PerfMetric], graded: Graded, where: str) -> int:
    """Print the verdict, ratios, regressions and gaps; the exit status."""
    verdict = "incomplete" if graded.problems else "regressed" if graded.regressed else "ok"
    print(f"quality-report: verdict={verdict} regressed={len(graded.regressed)} "
          f"improved={len(graded.improved)} metrics={sum(m.status == COLLECTED for m in metrics)}")
    print(f"compare: {where}")
    for line in graded.lines + graded.regressed:
        print(line)
    for metric in metrics:
        if metric.status == NOT_COLLECTED:
            print(f"not-collected: {metric.name} ({metric.reason})")
    for problem in graded.problems:
        print(f"problem: {problem}")
    return {"ok": 0, "regressed": 1, "incomplete": 2}[verdict]


def measure(root: str, hub: str, config: dict[str, object]) -> tuple[list[PerfMetric], dict[str, object], list[str]]:
    """(metrics, runner samples, problems) for one guarded run; nothing runs when refused."""
    plan, metrics, problems = parse_plan(config)
    problems += [f"refused: {reason}" for reason in refusals(root)]
    samples: dict[str, object] = {}
    if not problems:
        try:
            samples = launch(root, hub, plan)
        except (OSError, json.JSONDecodeError) as exc:
            problems.append(str(exc))
    if problems:
        for metric in metrics:
            metric.status, metric.reason = NOT_COLLECTED, "not measured"
        return metrics, samples, problems
    return metrics, samples, fill(metrics, samples)


def write_measurements(root: str, model: str, where: str, metrics: list[PerfMetric]) -> None:
    """logs/code-quality/perf/measurements.json: this run's raw samples, written in every mode."""
    rows = {m.name: {"unit": m.unit, "better": m.better, "status": m.status, "reason": m.reason,
                     "samples": m.samples} for m in metrics}
    with open(os.path.join(root, OUT, "measurements.json"), "w", encoding="utf-8") as fh:
        json.dump({"cpu_model": model, "sha": git(root, "rev-parse", "HEAD"), "baseline": where,
                   "metrics": rows}, fh, indent=2, sort_keys=True)
        fh.write("\n")


def run(root: str, hub: str, config: dict[str, object], update: bool) -> int:
    """Measure, then compare with or (--update-baseline) rewrite perf/baseline-<cpu>.json."""
    os.makedirs(os.path.join(root, OUT), exist_ok=True)
    try:
        model = cpu_model()
    except OSError as exc:
        return report([], Graded(problems=[str(exc)]), "none")
    path = baseline_path(root, model)
    where = os.path.relpath(path, root)
    metrics, samples, problems = measure(root, hub, config)
    write_measurements(root, model, where, metrics)
    if update:
        problems += [f"refused: {m.name} spread {m.spread():.1%} is above {MAX_BASELINE_SPREAD:.0%}"
                     for m in metrics if m.status == COLLECTED and m.spread() > MAX_BASELINE_SPREAD]
        if not problems:
            write_baseline(path, root, model, samples, metrics)
        return report(metrics, Graded(problems=problems),
                      "none (not written)" if problems else f"{where} (written)")
    baseline, missing = read_baseline(path, model)
    graded = grade(metrics, baseline, where)
    graded.problems = problems + (missing if not problems else []) + graded.problems
    return report(metrics, graded, where)
