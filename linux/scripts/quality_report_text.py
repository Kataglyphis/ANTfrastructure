# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Allow-row, suppression, doc-length, drift and declared tree metrics for quality-report.
Suppressions are found by literal marker text, so a marker spelled another way is not counted;
see docs/code-quality-tooling.md#quality-report"""

from __future__ import annotations

import contextlib
import io
import json
import os
import re
import subprocess
import sys
from fnmatch import fnmatch

from quality_allow import iter_rows
from quality_report_model import (
    CODE,
    LOWER,
    REPORT,
    Item,
    Metric,
    by_file_weight,
    failed,
    keyed,
    missing,
    normalise,
    tracked,
)
from quality_report_tree import Context, load_json, run, table, total

# The goal's nothing-loosened markers, split in two so this table is not itself a suppression site.
MARKERS = (
    ("shellcheck_disable", r"#\s*shell" + r"check\s+disable"),
    *((slug, re.escape(head + tail)) for slug, head, tail in (
        ("suppress_message", "Suppress", "Message"),
        ("no_qa", "# no", "qa"),
        ("no_sec", "# no", "sec"),
        ("no_lint", "NO", "LINT"),
        ("type_ignore", "type: ", "ignore"),
        ("ty_ignore", "ty: ", "ignore"),
        ("pyright_ignore", "pyright: ", "ignore"),
        ("rust_allow", "#[al", "low("),
        ("dart_ignore", "// ", "ignore:"),
        ("pragma_no_cover", "pragma: ", "no cover"),
        ("lcov_excl", "LCOV_", "EXCL"),
        ("gcovr_excl", "GCOVR_", "EXCL"),
        ("gtest_skip", "GTEST_", "SKIP"),
        ("pytest_skip", "pytest.mark.", "skip"),
        ("import_or_skip", "importor", "skip"),
        ("x_fail", "x", "fail"),
        ("rust_ignore", "#[ig", "nore]"),
    )),
)
PROSE = (".md", ".rst", ".adoc")
# Vendored trees follow their upstream, so the scanners' third_party exclusion applies here too.
VENDORED = "third_party/"


def text_lines(root: str, rel: str) -> list[str] | None:
    """A tracked file's lines, or None for a binary file."""
    with open(os.path.join(root, rel), "rb") as source:
        data = source.read()
    if b"\0" in data[:8192]:
        return None
    return data.decode("utf-8", errors="replace").splitlines()


def suppressions(ctx: Context) -> list[Metric]:
    """One set metric per marker over tracked non-prose files, keyed without line numbers."""
    found: dict[str, list[tuple[str, int, str]]] = {slug: [] for slug, _rx in MARKERS}
    patterns = [(slug, re.compile(rx)) for slug, rx in MARKERS]
    for rel in tracked(ctx.root):
        if rel.endswith(PROSE) or rel.startswith(VENDORED):
            continue
        lines = text_lines(ctx.root, rel)
        for number, line in enumerate(lines or [], 1):
            for slug, rx in patterns:
                if rx.search(line):
                    found[slug].append((rel, number, normalise(line)))
    metrics = []
    for slug, rx in MARKERS:
        rows = found[slug]
        members = keyed([(f"{rel}|{slug}", text) for rel, _n, text in rows])
        metrics.append(Metric(f"suppressions.{slug}", len(rows), "sites", LOWER, CODE,
                              f"git ls-files | grep -E '{rx}' (prose and third_party excluded)",
                              members=members, items=by_file_weight(rows)))
    return metrics


def allow_rows(ctx: Context) -> list[Metric]:
    """Rows per tracked *.allow file and the summed count column of those that carry one."""
    metrics, budget_items, budget = [], [], 0
    for rel in tracked(ctx.root, "*.allow"):
        if rel.startswith(VENDORED):
            continue
        lines = text_lines(ctx.root, rel) or []
        rows = [(n, line.strip()) for n, line in enumerate(lines, 1)
                if line.strip() and not line.strip().startswith("#")]
        counts = budget_rows(os.path.join(ctx.root, rel))
        weights = {n: c for n, c in counts} if counts else {}
        items = [Item(rel, n, weights.get(n, 1), text[:120]) for n, text in rows]
        metrics.append(Metric(f"allow_rows.{rel}", len(rows), "rows", LOWER, CODE,
                              f"quality_allow rows of {rel}", items=items))
        for n, c in counts or []:
            budget += c
            budget_items.append(Item(rel, n, c, f"budget {c}"))
    metrics.append(Metric("allow_budget_total", budget, "units", LOWER, CODE,
                          "quality_allow.iter_rows count column, summed over *.allow",
                          items=budget_items))
    return metrics


def budget_rows(path: str) -> list[tuple[int, int]] | None:
    """(line, count) per row when every row has a count column, else None."""
    sink = io.StringIO()
    try:
        with contextlib.redirect_stderr(sink):
            return [(num, cnt) for _key, cnt, _reason, num in iter_rows(path)]
    except SystemExit:
        return None


def doc_lengths(ctx: Context) -> list[Metric]:
    """AGENTS.md and root README.md line counts, reported, never graded."""
    metrics = []
    for name, rel in (("agents_md_lines", "AGENTS.md"), ("readme_lines", "README.md")):
        path = os.path.join(ctx.root, rel)
        if not os.path.isfile(path):
            metrics.append(missing(name, "lines", LOWER, REPORT, f"wc -l {rel}", f"no {rel}"))
            continue
        metrics.append(Metric(name, len(text_lines(ctx.root, rel) or []), "lines", LOWER, REPORT,
                              f"wc -l {rel}"))
    return metrics


def agents_drift(ctx: Context) -> Metric:
    """Clause-9 drift findings, once the pinned hub carries verify_agents_drift.py."""
    script = "linux/scripts/verify_agents_drift.py"
    out = os.path.join(ctx.work, "agents-drift.json")
    source = f"python3 {ctx.hub_display(script)} --root . --json {os.path.relpath(out, ctx.root)}"
    if not os.path.isfile(os.path.join(ctx.tools, script)):
        return missing("agents_drift_findings", "findings", LOWER, CODE, source,
                       "the pinned hub has no verify_agents_drift.py yet")
    rc, reason = run([sys.executable, os.path.join(ctx.tools, script), "--root", ctx.root,
                      "--json", out], ctx.root, os.path.join(ctx.work, "agents-drift.log"))
    try:
        if rc not in (0, 1):
            raise ValueError(f"exit {rc}: {reason}")
        doc = load_json(out)
        rows = doc.get("items", [])
        items = [Item(str(r["path"]), int(r["line"]), 1, str(r.get("detail", "")))
                 for r in rows if isinstance(r, dict)] if isinstance(rows, list) else []
        return Metric("agents_drift_findings", total(doc, "findings"), "findings", LOWER, CODE,
                      source, items=items)
    except (KeyError, TypeError, ValueError) as exc:
        return failed("agents_drift_findings", "findings", LOWER, CODE, source, str(exc))


def declared(ctx: Context) -> list[Metric]:
    """The [[metric]] rows of quality-report.toml: counted patterns and Ruff reruns."""
    rows = ctx.config.get("metric", [])
    metrics = []
    for row in rows if isinstance(rows, list) else []:
        kind = row.get("kind") if isinstance(row, dict) else None
        if kind == "pattern":
            metrics.append(pattern_metric(ctx, row))
        elif kind == "ruff":
            metrics.append(ruff_metric(ctx, row))
        else:
            name = str(row.get("name", "?")) if isinstance(row, dict) else "?"
            metrics.append(failed(name, "", LOWER, CODE, "quality-report.toml",
                                  f"unknown declared metric kind {kind!r}"))
    return metrics


def strings(row: dict[str, object], key: str) -> list[str]:
    """A declared list of strings; a scalar becomes a one-element list."""
    value = row.get(key, [])
    values = [value] if isinstance(value, str) else value
    if not isinstance(values, list) or not all(isinstance(v, str) for v in values):
        raise ValueError(f"`{key}` must be a string or a list of strings")
    return list(values)


def selected(ctx: Context, row: dict[str, object]) -> list[str]:
    """Tracked files under the declared paths, filtered by include and exclude globs."""
    files = tracked(ctx.root, *(strings(row, "paths") or ["."]))
    include, exclude = strings(row, "include"), strings(row, "exclude")
    return [rel for rel in files
            if (not include or any(fnmatch(rel, g) for g in include))
            and not any(fnmatch(rel, g) for g in exclude)]


def declared_meta(row: dict[str, object]) -> tuple[str, str, str, str]:
    """(name, unit, better, class) of one declared metric."""
    name = row.get("name")
    if not isinstance(name, str) or not re.fullmatch(r"[a-z0-9_.-]+", name):
        raise ValueError(f"declared metric name {name!r} must match [a-z0-9_.-]+")
    return (name, str(row.get("unit", "matches")), str(row.get("better", LOWER)),
            str(row.get("class", CODE)))


def pattern_metric(ctx: Context, row: dict[str, object]) -> Metric:
    """A counted regex over declared paths, set-valued so a swapped match still regresses."""
    name = str(row.get("name", "?"))
    try:
        name, unit, better, klass = declared_meta(row)
        rx = re.compile(str(row["pattern"]))
        hits = []
        for rel in selected(ctx, row):
            for number, line in enumerate(text_lines(ctx.root, rel) or [], 1):
                if rx.search(line):
                    hits.append((rel, number, normalise(line)))
    except (KeyError, ValueError, re.error) as exc:
        return failed(name, "matches", LOWER, CODE, "quality-report.toml", str(exc))
    source = f"git ls-files {' '.join(strings(row, 'paths'))} | grep -E '{row['pattern']}'"
    return Metric(name, len(hits), unit, better, klass, source,
                  members=keyed([(rel, text) for rel, _n, text in hits]),
                  items=by_file_weight(hits))


def ruff_metric(ctx: Context, row: dict[str, object]) -> Metric:
    """Locked Ruff over declared paths with declared --config overrides."""
    name = str(row.get("name", "?"))
    ruff = os.path.join(ctx.root, "logs/code-quality/python-static/.venv/bin/ruff")
    try:
        name, unit, better, klass = declared_meta(row)
        files = [rel for rel in selected(ctx, row) if rel.endswith(".py")]
        overrides = [arg for value in strings(row, "config") for arg in ("--config", value)]
        source = " ".join(["ruff check --output-format json", *overrides, "--",
                           *strings(row, "paths")])
        if not files:
            return Metric(name, 0, unit, better, klass, source)
        if not os.access(ruff, os.X_OK):
            raise ValueError("the locked Ruff from python-static.sh is missing")
        proc = subprocess.run([ruff, "check", "--no-fix", "--exit-zero", "--output-format", "json",
                               *overrides, "--", *files], cwd=ctx.root, capture_output=True,
                              text=True, check=False)
        if proc.returncode != 0:
            raise ValueError(f"ruff exit {proc.returncode}: {proc.stderr.strip()[-300:]}")
        found = json.loads(proc.stdout)
        hits = [(os.path.relpath(f["filename"], ctx.root), int(f["location"]["row"]),
                 f"{f['code']} {f['message']}") for f in found]
    except (KeyError, ValueError, TypeError) as exc:
        return failed(name, "findings", LOWER, CODE, "quality-report.toml", str(exc))
    return Metric(name, len(hits), unit, better, klass, source, items=by_file_weight(hits))


def declared_outputs(config: dict[str, object]) -> dict[str, object]:
    """The docs build list and the [[output]] rows (benchmark, golden, latency), kept for readers."""
    return {key: config[key] for key in ("docs", "output") if key in config}


def docs_build_list(ctx: Context) -> list[str]:
    """Problems with the declared docs build list file; an absent declaration is not one."""
    docs = ctx.config.get("docs")
    if not isinstance(docs, dict) or "build_list" not in docs:
        return []
    rel = str(docs["build_list"])
    if not os.path.isfile(os.path.join(ctx.root, rel)):
        return [f"docs build list {rel} declared in quality-report.toml does not exist"]
    return []


__all__ = ["agents_drift", "allow_rows", "declared", "declared_outputs", "doc_lengths",
           "docs_build_list", "suppressions", "table"]
