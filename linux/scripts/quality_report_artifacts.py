# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Artifact metrics for quality-report: JUnit, coverage, mutation, clang-tidy and counted logs.
It reads only the files quality-report.toml declares; see docs/code-quality-tooling.md#quality-report"""

from __future__ import annotations

import glob
import json
import os
import re
import xml.parsers.expat
from collections.abc import Callable
from dataclasses import dataclass, field

import quality_report_github as github
from quality_report_model import (
    CODE,
    HIGHER,
    LOWER,
    Item,
    Metric,
    by_file_weight,
    failed,
    missing,
)


@dataclass(frozen=True)
class Source:
    """One [[artifact]] row: what to read, where, and which lane artifact carries it."""

    name: str
    kind: str
    paths: tuple[str, ...]
    artifact: str | None
    workflow: str | None
    options: dict[str, object]


@dataclass
class Fetch:
    """How a run may reach lane artifacts: the repo, the commit, and whether network is allowed."""

    root: str
    work: str
    slug: str | None
    sha: str
    offline: bool


@dataclass
class Reading:
    """One metric a reader produced: name suffix, value, better direction, queue items, set members."""

    suffix: str
    value: float | None
    better: str
    unit: str
    items: list[Item] = field(default_factory=list)
    members: list[str] | None = None


def sources(config: dict[str, object]) -> list[Source]:
    """The declared artifact rows; a malformed row raises ValueError."""
    rows = config.get("artifact", [])
    if not isinstance(rows, list):
        raise TypeError("[[artifact]] must be an array of tables")
    found = []
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("name"), str):
            raise TypeError("every [[artifact]] needs a string name")
        paths = row.get("path")
        paths = [paths] if isinstance(paths, str) else paths
        if not isinstance(paths, list) or not paths or not all(isinstance(p, str) for p in paths):
            raise ValueError(f"[[artifact]] {row['name']} needs a path glob or a list of them")
        found.append(Source(str(row["name"]), str(row.get("kind", "")), tuple(paths),
                            row.get("artifact") if isinstance(row.get("artifact"), str) else None,
                            row.get("workflow") if isinstance(row.get("workflow"), str) else None,
                            {k: v for k, v in row.items()
                             if k not in ("name", "kind", "path", "artifact", "workflow")}))
    return found


def matches(base: str, patterns: tuple[str, ...], anywhere: bool) -> list[str]:
    """Files under base matching the globs; inside a downloaded artifact only the basename counts."""
    found: set[str] = set()
    for pattern in patterns:
        rel = f"**/{os.path.basename(pattern)}" if anywhere else pattern
        found.update(p for p in glob.glob(os.path.join(base, rel), recursive=True)
                     if os.path.isfile(p))
    return sorted(found)


def locate(source: Source, fetch: Fetch) -> tuple[list[str], str]:
    """(files, where) for one source: the checkout first, then a same-SHA lane artifact."""
    local = matches(fetch.root, source.paths, anywhere=False)
    if local:
        return local, "checkout"
    if source.artifact is None:
        raise github.Unavailable(f"no file matches {', '.join(source.paths)}")
    if fetch.offline:
        raise github.Unavailable(f"no local file and --offline skips the {source.artifact} artifact")
    if fetch.slug is None:
        raise github.Unavailable("the checkout has no GitHub origin")
    target = github.same_sha_artifact(fetch.slug, fetch.sha, source.artifact, source.workflow,
                                      os.path.join(fetch.work, "artifacts"))
    found = matches(target, source.paths, anywhere=True)
    if not found:
        raise github.Unavailable(f"artifact {source.artifact} holds no {', '.join(source.paths)}")
    return found, f"artifact {source.artifact}"


class JUnit:
    """Expat reader of one JUnit file: per testcase its start line and outcome."""

    def __init__(self) -> None:
        self.cases: list[tuple[int, str, str]] = []
        self.current: list[object] | None = None
        self.parser = xml.parsers.expat.ParserCreate()
        self.parser.StartElementHandler = self.start
        self.parser.EndElementHandler = self.end

    def start(self, tag: str, attrs: dict[str, str]) -> None:
        if tag == "testcase":
            name = f"{attrs.get('classname', '')}.{attrs.get('name', '')}".strip(".")
            self.current = [self.parser.CurrentLineNumber, name, "passed"]
        elif self.current is not None and tag in ("skipped", "failure", "error"):
            self.current[2] = "skipped" if tag == "skipped" else "failed"

    def end(self, tag: str) -> None:
        if tag == "testcase" and self.current is not None:
            line, name, outcome = self.current
            self.cases.append((int(str(line)), str(name), str(outcome)))
            self.current = None


def read_junit(_source: Source, files: list[str], root: str) -> list[Reading]:
    """(suffix, value, items): passed and skipped testcases over every matched file."""
    passed, skipped = 0, []
    for path in files:
        reader = JUnit()
        with open(path, "rb") as fh:
            reader.parser.ParseFile(fh)
        rel = os.path.relpath(path, root)
        passed += sum(1 for _l, _n, outcome in reader.cases if outcome == "passed")
        skipped += [(rel, line, name) for line, name, outcome in reader.cases if outcome == "skipped"]
    return [Reading("tests_passed", passed, HIGHER, "tests"),
            Reading("tests_skipped", len(skipped), LOWER, "tests", by_file_weight(skipped))]


def _ratio(hit: float, total: float) -> float | None:
    return round(100.0 * hit / total, 2) if total else None


def _cobertura(text: str) -> tuple[float | None, float | None]:
    head = re.search(r"<coverage\b([^>]*)>", text)
    if head is None:
        raise ValueError("no <coverage> element")
    attrs = dict(re.findall(r'([\w-]+)="([^"]*)"', head.group(1)))
    lines = _ratio(float(attrs.get("lines-covered", 0)), float(attrs.get("lines-valid", 0)))
    branches = _ratio(float(attrs.get("branches-covered", 0)), float(attrs.get("branches-valid", 0)))
    if lines is None and "line-rate" in attrs:
        lines = round(100.0 * float(attrs["line-rate"]), 2)
    return lines, branches


def _lcov(text: str) -> tuple[float | None, float | None]:
    sums = {key: 0 for key in ("LF", "LH", "BRF", "BRH")}
    for key, value in re.findall(r"^(LF|LH|BRF|BRH):(\d+)$", text, re.MULTILINE):
        sums[key] += int(value)
    if not sums["LF"]:
        raise ValueError("no LF: records")
    return _ratio(sums["LH"], sums["LF"]), _ratio(sums["BRH"], sums["BRF"])


def _coverage_json(text: str) -> tuple[float | None, float | None]:
    doc = json.loads(text)
    if isinstance(doc, dict) and isinstance(doc.get("totals"), dict):
        totals = doc["totals"]
        return (_ratio(totals["covered_lines"], totals["num_statements"]),
                _ratio(totals.get("covered_branches", 0), totals.get("num_branches", 0)))
    if isinstance(doc, dict) and isinstance(doc.get("data"), list) and doc["data"]:
        totals = doc["data"][0]["totals"]
        return (_ratio(totals["lines"]["covered"], totals["lines"]["count"]),
                _ratio(totals["branches"]["covered"], totals["branches"]["count"]))
    if isinstance(doc, dict) and "line_total" in doc:
        return (_ratio(doc["line_covered"], doc["line_total"]),
                _ratio(doc.get("branch_covered", 0), doc.get("branch_total", 0)))
    raise ValueError("neither a coverage.py, llvm-cov nor gcovr summary JSON")


COVERAGE_READERS: dict[str, Callable[[str], tuple[float | None, float | None]]] = {
    "cobertura": _cobertura, "lcov": _lcov, "json": _coverage_json}


def read_coverage(source: Source, files: list[str], _root: str) -> list[Reading]:
    """Line and branch coverage of one leg; several files average by their own ratios."""
    fmt = str(source.options.get("format", "cobertura"))
    if fmt not in COVERAGE_READERS:
        raise ValueError(f"unknown coverage format {fmt!r}")
    pairs = []
    for path in files:
        with open(path, encoding="utf-8") as fh:
            pairs.append(COVERAGE_READERS[fmt](fh.read()))
    lines = [p[0] for p in pairs if p[0] is not None]
    branches = [p[1] for p in pairs if p[1] is not None]
    if not lines:
        raise ValueError("the coverage report holds no line data")
    branch = round(sum(branches) / len(branches), 2) if branches else None
    return [Reading("line_coverage", round(sum(lines) / len(lines), 2), HIGHER, "percent"),
            Reading("branch_coverage", branch, HIGHER, "percent")]


# verify_mutations.py prints one bites, skip or FAIL line per selected recipe, [k/n]-prefixed when sharded.
MUTATION_SELECTED = r"^(?:\[\d+/\d+\])?[ \t]+(?:bites|skip)[ \t]|^(?:\[\d+/\d+\][ \t]*)?FAIL: "
MUTATION_CAUGHT = r"^(?:\[\d+/\d+\])?[ \t]+bites[ \t]"


def read_mutation(source: Source, files: list[str], root: str) -> list[Reading]:
    """Selected and caught recipes, counted as report lines matching the declared regexes."""
    selected_rx = re.compile(str(source.options.get("selected", MUTATION_SELECTED)), re.MULTILINE)
    caught_rx = re.compile(str(source.options.get("caught", MUTATION_CAUGHT)), re.MULTILINE)
    selected = caught = 0
    for path in files:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        selected += len(selected_rx.findall(text))
        caught += len(caught_rx.findall(text))
    if not selected:
        shown = ", ".join(os.path.relpath(f, root) for f in files)
        raise ValueError(f"no selected mutation recipe in {shown}")
    return [Reading("mutations_selected", selected, HIGHER, "recipes"),
            Reading("mutations_caught", caught, HIGHER, "recipes")]


TIDY = re.compile(r"^(?P<path>[^:\s][^:]*):(?P<line>\d+):\d+: (?:warning|error): .*\[(?P<check>[\w.,-]+)\]$")


def repo_relative(path: str, root: str) -> str:
    """A report path made repo-relative: the longest suffix that exists in the checkout."""
    parts = path.replace("\\", "/").split("/")
    for i in range(len(parts)):
        rel = "/".join(parts[i:])
        if rel and os.path.exists(os.path.join(root, rel)):
            return rel
    return path


def read_tidy(_source: Source, files: list[str], root: str) -> list[Reading]:
    """clang-tidy findings as a file|check set; a new pair regresses even when the count holds."""
    rows = []
    for path in files:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                match = TIDY.match(line.rstrip())
                if match:
                    rel = repo_relative(match.group("path"), root)
                    for check in match.group("check").split(","):
                        rows.append((rel, int(match.group("line")), check))
    members = sorted({f"{rel}|{check}" for rel, _n, check in rows})
    return [Reading("clang_tidy", len(members), LOWER, "file|check pairs", by_file_weight(rows),
                    members)]


def read_count(source: Source, files: list[str], root: str) -> list[Reading]:
    """Lines matching a declared regex in a lane log; `location` finds the source line nearby."""
    rx = re.compile(str(source.options.get("pattern", "")))
    where = re.compile(str(source.options.get("location", r"(?P<path>[^\s:]+):(?P<line>\d+)")))
    rows = []
    for path in files:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
        for n, line in enumerate(lines):
            if rx.search(line):
                rows.append(_count_item(lines, n, where, root) or (os.path.relpath(path, root), n + 1, line.strip()))
    return [Reading("", len(rows), LOWER, str(source.options.get("unit", "lines")), by_file_weight(rows))]


def _count_item(lines: list[str], n: int, where: re.Pattern[str], root: str) -> tuple[str, int, str] | None:
    for follow in lines[n:n + 6]:
        match = where.search(follow)
        if match and "path" in where.groupindex and "line" in where.groupindex:
            return repo_relative(match.group("path"), root), int(match.group("line")), lines[n].strip()
    return None


READERS: dict[str, Callable[[Source, list[str], str], list[Reading]]] = {
    "junit": read_junit, "coverage": read_coverage, "mutation": read_mutation,
    "clang-tidy": read_tidy, "count": read_count}
# What each kind produces when its source cannot be read: (suffix, better, unit).
SHAPES = {
    "junit": (("tests_passed", HIGHER, "tests"), ("tests_skipped", LOWER, "tests")),
    "coverage": (("line_coverage", HIGHER, "percent"), ("branch_coverage", HIGHER, "percent")),
    "mutation": (("mutations_selected", HIGHER, "recipes"), ("mutations_caught", HIGHER, "recipes")),
    "clang-tidy": (("clang_tidy", LOWER, "file|check pairs"),),
    "count": (("", LOWER, "lines"),),
}


def metric_name(suffix: str, source: Source) -> str:
    """`<suffix>.<source>`, or the bare source name for a counted log."""
    return f"{suffix}.{source.name}" if suffix else source.name


def collect(config: dict[str, object], fetch: Fetch) -> list[Metric]:
    """Every declared artifact metric: collected, not-collected (absent) or failed (unreadable)."""
    try:
        rows = sources(config)
    except (TypeError, ValueError) as exc:
        return [failed("artifacts", "", LOWER, CODE, "quality-report.toml", str(exc))]
    metrics: list[Metric] = []
    for source in rows:
        metrics.extend(collect_source(source, fetch))
    return metrics


def collect_source(source: Source, fetch: Fetch) -> list[Metric]:
    """The metrics of one declared source."""
    shape = SHAPES.get(source.kind)
    if shape is None:
        return [failed(source.name, "", LOWER, CODE, "quality-report.toml",
                       f"unknown artifact kind {source.kind!r}")]
    where = f"{source.kind} {', '.join(source.paths)}"
    try:
        files, origin = locate(source, fetch)
        readings = READERS[source.kind](source, files, fetch.root)
    except github.Unavailable as exc:
        return [missing(metric_name(s, source), unit, better, CODE, where, str(exc))
                for s, better, unit in shape]
    except (github.Broken, OSError, ValueError, KeyError, TypeError,
            xml.parsers.expat.ExpatError) as exc:
        return [failed(metric_name(s, source), unit, better, CODE, where, str(exc))
                for s, better, unit in shape]
    metrics = []
    for reading in readings:
        name = metric_name(reading.suffix, source)
        if reading.value is None:
            metrics.append(missing(name, reading.unit, reading.better, CODE, where,
                                   "the report carries no such data"))
            continue
        metrics.append(Metric(name, reading.value, reading.unit, reading.better, CODE,
                              f"{where} ({origin})", members=reading.members,
                              items=reading.items))
    return metrics
