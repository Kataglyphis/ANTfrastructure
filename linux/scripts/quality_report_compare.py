# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Grading, queue and summary of quality-report; it compares records, it does not attribute causes.
See docs/code-quality-tooling.md#quality-report"""

from __future__ import annotations

import json
from dataclasses import dataclass, field

from quality_report_model import (
    CODE,
    COLLECTED,
    FAILED,
    LOWER,
    SCHEMA_VERSION,
    Metric,
)

QUEUE_DEPTH = 10


@dataclass
class Grade:
    """The comparison of one record with a baseline."""

    regressed: list[tuple[str, str, str]] = field(default_factory=list)
    improved: list[tuple[str, str, str]] = field(default_factory=list)
    new_members: dict[str, list[str]] = field(default_factory=dict)
    problems: list[str] = field(default_factory=list)

    def verdict(self, metrics: list[Metric]) -> str:
        """incomplete beats regressed beats ok."""
        if self.problems or any(m.status == FAILED for m in metrics):
            return "incomplete"
        return "regressed" if self.regressed else "ok"


def load_baseline(path: str) -> dict[str, dict[str, object]]:
    """The metrics table of a previous measurements.json; a malformed one raises ValueError."""
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"compare file {path} is unreadable: {exc}") from None
    if not isinstance(doc, dict) or doc.get("schema_version") != SCHEMA_VERSION:
        raise ValueError(f"compare file {path} is not a schema_version {SCHEMA_VERSION} record")
    metrics = doc.get("metrics")
    if not isinstance(metrics, dict) or not all(isinstance(v, dict) for v in metrics.values()):
        raise ValueError(f"compare file {path} has no metrics table")
    return metrics


def shown(value: object) -> str:
    """A value as REGRESSED lines print it."""
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return str(value)


def grade(metrics: list[Metric], baseline: dict[str, dict[str, object]] | None) -> Grade:
    """Regressions and improvements of collected code metrics that the baseline also collected."""
    result = Grade()
    for metric in metrics:
        before = (baseline or {}).get(metric.name)
        if (before is None or metric.klass != CODE or metric.status != COLLECTED
                or before.get("status", COLLECTED) != COLLECTED):
            continue
        old = before.get("value")
        if not isinstance(old, (int, float)) or metric.value is None:
            result.problems.append(f"baseline value of {metric.name} is not a number")
            continue
        row = (metric.name, shown(old), shown(metric.value))
        change = movement(metric, old, before.get("members"))
        if isinstance(change, list):
            result.regressed.append(row)
            result.new_members[metric.name] = change
        elif change > 0:
            result.regressed.append(row)
        elif change < 0:
            result.improved.append(row)
    return result


def movement(metric: Metric, old: float, members: object) -> int | list[str]:
    """New set members, or +1 worse, -1 better, 0 held for one metric."""
    now = float(metric.value or 0)
    if metric.members is not None and isinstance(members, list):
        added = sorted(set(metric.members) - {str(m) for m in members})
        return added or (-1 if now < old else 0)
    worse = now > old if metric.better == LOWER else now < old
    if worse:
        return 1
    return -1 if (now < old if metric.better == LOWER else now > old) else 0


def queue(metrics: list[Metric], title: str) -> str:
    """queue.md: up to ten located items, worst first, per nonzero lower-is-better code metric."""
    sections = [f"# Quality queue: {title}", ""]
    for metric in sorted(metrics, key=lambda m: m.name):
        if (metric.klass != CODE or metric.better != LOWER or metric.status != COLLECTED
                or not metric.value):
            continue
        items = sorted(metric.items, key=lambda i: (-i.weight, i.path, i.line))[:QUEUE_DEPTH]
        sections += [f"## {metric.name}: {shown(metric.value)} {metric.unit}", ""]
        sections += [f"- {i.path}:{i.line} {i.detail}".rstrip() for i in items]
        if not items:
            sections.append("- (the collector located no item)")
        sections.append("")
    if len(sections) == 2:
        sections += ["No nonzero lower-is-better code metric.", ""]
    return "\n".join(sections)


def summary(metrics: list[Metric], result: Grade, verdict_line: str, baseline: str) -> str:
    """The step-summary Markdown: verdict, changes, uncollected metrics and every value."""
    lines = [f"### {verdict_line}", "", f"Baseline: {baseline}", ""]
    for title, rows in (("Regressed", result.regressed), ("Improved", result.improved)):
        if rows:
            lines += [f"#### {title}", "", "| metric | before | now |", "| --- | --- | --- |"]
            lines += [f"| {name} | {old} | {new} |" for name, old, new in rows]
            lines.append("")
    for name, added in result.new_members.items():
        lines += [f"New members of {name}:", ""] + [f"- `{m}`" for m in added[:20]] + [""]
    absent = [m for m in metrics if m.status != COLLECTED]
    if absent or result.problems:
        lines += ["#### Not collected", ""] + [f"- {m.name} ({m.reason})" for m in absent]
        lines += [f"- {p}" for p in result.problems] + [""]
    lines += ["#### Measurements", "", "| metric | value | unit | better | class |",
              "| --- | --- | --- | --- | --- |"]
    lines += [f"| {m.name} | {shown(m.value) if m.status == COLLECTED else m.status} | {m.unit} "
              f"| {m.better} | {m.klass} |" for m in sorted(metrics, key=lambda m: m.name)]
    return "\n".join(lines) + "\n"
