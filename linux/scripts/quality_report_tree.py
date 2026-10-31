# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Scanner, Ruff/ty and PowerShell tree metrics for quality-report; see docs/code-quality-tooling.md#quality-report"""

from __future__ import annotations

import ast
import json
import os
import re
import shutil
import subprocess
import sys
from collections.abc import Iterator
from dataclasses import dataclass, field

from quality_report_model import (
    CODE,
    LOWER,
    REPORT,
    Item,
    Metric,
    by_file_weight,
    failed,
    located,
    missing,
    tracked,
)
from verify_code_complexity import py_functions, shell_metrics
from verify_code_size import shell_functions

TOOLS = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


@dataclass
class Context:
    """One run's checkout, hub, scratch directory and declarations."""

    root: str
    hub: str
    work: str
    config: dict[str, object] = field(default_factory=dict)
    tools: str = TOOLS

    def hub_display(self, rel: str, base: str | None = None) -> str:
        """A hub path as the source command shows it: relative to the root when inside it."""
        path = os.path.normpath(os.path.join(base or self.tools, rel))
        inside = os.path.relpath(path, self.root)
        return path if inside.startswith("..") else inside

    def is_hub(self) -> bool:
        """True when the graded checkout is the hub hub-reuse would compare with."""
        return os.path.samefile(self.root, self.hub)

    def tools_are_root(self) -> bool:
        """True when the graded checkout holds these scripts, so their own default scopes apply."""
        return os.path.samefile(self.root, self.tools)


def run(cmd: list[str], cwd: str, log: str, env: dict[str, str] | None = None) -> tuple[int, str]:
    """Run one collector; its output lands in `log`, the last line comes back as a reason."""
    try:
        proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=False,
                              stdin=subprocess.DEVNULL, env=env)
    except OSError as exc:
        return 127, str(exc)
    with open(log, "w", encoding="utf-8") as out:
        out.write(proc.stdout + proc.stderr)
    lines = [line for line in (proc.stdout + proc.stderr).splitlines() if line.strip()]
    return proc.returncode, (lines[-1].strip() if lines else f"exit {proc.returncode}")


def load_json(path: str) -> dict[str, object]:
    """A collector's JSON record; a missing or malformed one raises ValueError."""
    try:
        with open(path, encoding="utf-8-sig") as source:
            doc = json.load(source)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"unreadable {os.path.basename(path)}: {exc}") from None
    if not isinstance(doc, dict):
        raise TypeError(f"{os.path.basename(path)} is not a JSON object")
    return doc


def table(doc: dict[str, object], key: str) -> dict[str, object]:
    """A nested JSON object, or ValueError naming the missing key."""
    value = doc.get(key)
    if not isinstance(value, dict):
        raise TypeError(f"JSON record has no `{key}` object")
    return value


def total(doc: dict[str, object], key: str) -> int:
    """One integer total of a scanner record."""
    value = table(doc, "totals").get(key)
    if not isinstance(value, int):
        raise TypeError(f"JSON totals have no integer `{key}`")
    return value


SCANNERS = (
    ("code-dupes", "docs/scripts/verify_code_dupes.py",
     ("--allow-empty", "--report-only", "--extra-languages")),
    ("code-size", "linux/scripts/verify_code_size.py", ("--report-only", "--extra-languages")),
    ("code-complexity", "linux/scripts/verify_code_complexity.py", ("--report-only",)),
    ("hub-reuse", "docs/scripts/verify_hub_reuse.py", ("--report-only",)),
)
# (metric, totals key, unit, class, read from the report_only section)
SCANNER_METRICS = {
    "code-dupes": (("duplicated_blocks", "pairs", "pairs", CODE, False),
                   ("python_duplicate_blocks", "pairs", "pairs", REPORT, True)),
    "code-size": (("functions_over_80_lines", "oversized_functions", "functions", CODE, False),
                  ("functions_over_80_lines_extra_languages", "oversized_functions",
                   "functions", REPORT, True)),
    "code-complexity": (("functions_over_complexity_15", "over_cc", "functions", CODE, False),),
    "hub-reuse": (("hub_reuse_pairs", "pairs", "pairs", CODE, False),),
}


def scanners(ctx: Context) -> list[Metric]:
    """The four hub scanners, read from their --json records."""
    metrics: list[Metric] = []
    for scanner, script, flags in SCANNERS:
        out = os.path.join(ctx.work, f"{scanner}.json")
        extra = ["--hub", ctx.hub_display(".", ctx.hub)] if scanner == "hub-reuse" else []
        source = " ".join(["python3", ctx.hub_display(script), "--root", ".", *flags, *extra,
                           "--json", os.path.relpath(out, ctx.root)])
        if scanner == "hub-reuse" and ctx.is_hub():
            metrics.append(missing("hub_reuse_pairs", "pairs", LOWER, CODE, source,
                                   "the root is the hub itself, so there is no pinned hub"))
            continue
        hub_args = ["--hub", ctx.hub] if extra else []
        rc, reason = run([sys.executable, os.path.join(ctx.tools, script), "--root", ctx.root,
                          *flags, *hub_args, "--json", out], ctx.root,
                         os.path.join(ctx.work, f"{scanner}.log"))
        metrics.extend(scanner_metrics(ctx, scanner, out, source, (rc, reason)))
    return metrics


def scanner_metrics(ctx: Context, scanner: str, out: str, source: str,
                    status: tuple[int, str]) -> list[Metric]:
    """Metrics of one scanner record; a failed run or a malformed record fails each of them."""
    specs = SCANNER_METRICS[scanner]
    try:
        if status[0] != 0:
            raise ValueError(f"exit {status[0]}: {status[1]}")
        doc = load_json(out)
        metrics = []
        for name, key, unit, klass, extra in specs:
            if extra:
                part = doc.get("report_only")
                value = total(part, key) if isinstance(part, dict) else None
                if value is None:
                    raise ValueError("JSON record has no report_only section")
            else:
                value = total(doc, key)
            metrics.append(Metric(name, value, unit, LOWER, klass, source,
                                  items=[] if extra else scanner_items(ctx, scanner, doc)))
        return metrics
    except (TypeError, ValueError) as exc:
        return [failed(name, unit, LOWER, klass, source, str(exc))
                for name, _key, unit, klass, _extra in specs]


def scanner_items(ctx: Context, scanner: str, doc: dict[str, object]) -> list[Item]:
    """Queue entries: located pairs from the record, or functions found in its flagged files."""
    if scanner in ("code-dupes", "hub-reuse"):
        rows = doc.get("items")
        if not isinstance(rows, list):
            raise ValueError("JSON record has no items list")
        return [Item(str(r["path"]), int(r["line"]), float(r["shingles"]),
                     f"{r['shingles']} shared shingles with {r['other']}")
                for r in rows if isinstance(r, dict)]
    files = table(doc, "files")
    key = "oversized_functions" if scanner == "code-size" else "over_cc"
    flagged = [rel for rel, row in files.items() if isinstance(row, dict) and row.get(key)]
    limits = table(doc, "limits")
    if scanner == "code-size":
        return list(oversized(ctx.root, flagged, int(str(limits["function_lines"]))))
    return list(complex_functions(ctx.root, flagged, int(str(limits["cc"]))))


def py_defs(path: str) -> dict[str, tuple[int, int]]:
    """Qualified name -> (first line, line count) per def, named as the size scanners name them."""
    try:
        with open(path, encoding="utf-8", errors="replace") as source:
            tree = ast.parse(source.read())
    except (OSError, SyntaxError):
        return {}
    found: dict[str, tuple[int, int]] = {}

    def walk(node: ast.AST, prefix: str) -> None:
        for child in ast.iter_child_nodes(node):
            if isinstance(child, ast.ClassDef):
                walk(child, prefix + child.name + ".")
            elif isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                length = (child.end_lineno or child.lineno) - child.lineno + 1
                if length > found.get(prefix + child.name, (0, 0))[1]:
                    found[prefix + child.name] = (child.lineno, length)
                walk(child, prefix + child.name + ".")
    walk(tree, "")
    return found


def oversized(root: str, rels: list[str], limit: int) -> Iterator[Item]:
    """Functions over the size limit in the files the size record flags."""
    for rel in rels:
        path = os.path.join(root, rel)
        if rel.endswith(".py"):
            rows = [(name, first, n) for name, (first, n) in py_defs(path).items()]
        else:
            rows = [(name, start, len(body)) for _r, name, start, body in shell_functions(path, rel)]
        for name, first, n in rows:
            if n > limit:
                yield Item(rel, first, n, f"{name} = {n} lines")


def complex_functions(root: str, rels: list[str], limit: int) -> Iterator[Item]:
    """Functions over the complexity limit in the files the complexity record flags."""
    for rel in rels:
        path = os.path.join(root, rel)
        if rel.endswith(".py"):
            lines = py_defs(path)
            rows = [(name, lines.get(name, (1, 0))[0], cc) for _r, name, cc, _n in py_functions(path, rel)]
        else:
            rows = [(name, start, shell_metrics(body)[0])
                    for _r, name, start, body in shell_functions(path, rel)]
        for name, first, cc in rows:
            if cc > limit:
                yield Item(rel, first, cc, f"{name} cc={cc}")


def python_static(ctx: Context) -> list[Metric]:
    """Ruff and ty counts exactly as python-static.sh grades them, with its locked tools."""
    source = (f"VIRTUAL_ENV=<empty venv> bash {ctx.hub_display('linux/scripts/python-static.sh')} "
              "--root . --report-only")
    names = (("ruff_findings", "findings", CODE), ("ty_diagnostics", "diagnostics", CODE),
             ("ty_unresolved_imports", "diagnostics", REPORT))
    if not tracked(ctx.root, "*.py"):
        return [Metric(name, 0, unit, LOWER, klass, "no tracked Python files")
                for name, unit, klass in names]
    log = os.path.join(ctx.work, "python-static.log")
    empty = os.path.join(ctx.work, "ty-env")
    rc, reason = run(["uv", "venv", "--clear", "--quiet", "--no-project", "--python", "3.14", empty],
                     ctx.root, log)
    if rc == 0:
        # ty resolves imports through VIRTUAL_ENV; an empty one keeps host packages out of the count.
        rc, reason = run(["bash", os.path.join(ctx.tools, "linux/scripts/python-static.sh"),
                          "--root", ctx.root, "--report-only"], ctx.root, log,
                         {**os.environ, "VIRTUAL_ENV": empty})
    report = os.path.join(ctx.root, "logs/code-quality/python-static")
    try:
        if rc != 0:
            raise ValueError(f"exit {rc}: {reason}")
        summary = dict(re.findall(r"([\w-]+)=(\S+)", read_text(os.path.join(report, "summary.txt"))))
        ruff = [row for row in map(located, read_text(os.path.join(report, "ruff.txt")).splitlines()) if row]
        ty = [row for row in map(located, read_text(os.path.join(report, "ty.txt")).splitlines()) if row]
        unresolved = [row for row in ty if "[unresolved-import]" in row[2]]
        values = (int(summary["ruff-findings"]), int(summary["ty-diagnostics"]), len(unresolved))
    except (KeyError, TypeError, ValueError) as exc:
        return [failed(name, unit, LOWER, klass, source, str(exc)) for name, unit, klass in names]
    return [Metric(name, value, unit, LOWER, klass, source, items=by_file_weight(rows))
            for (name, unit, klass), value, rows in zip(names, values, (ruff, ty, unresolved),
                                                        strict=True)]


def read_text(path: str) -> str:
    """A collector report; an unreadable one raises ValueError."""
    try:
        with open(path, encoding="utf-8", errors="replace") as source:
            return source.read()
    except OSError as exc:
        raise ValueError(f"unreadable {os.path.basename(path)}: {exc}") from None


def powershell(ctx: Context) -> Metric:
    """Invoke-CodeComplexity.ps1 findings over every tracked PowerShell file."""
    script = "windows/scripts/Invoke-CodeComplexity.ps1"
    out = os.path.join(ctx.work, "powershell-complexity.json")
    listing = os.path.join(ctx.work, "powershell-files.txt")
    files = [rel for rel in tracked(ctx.root, "*.ps1", "*.psm1")
             if not re.search(r"(^|/)archive/", rel, re.IGNORECASE)]
    selection = "" if ctx.tools_are_root() else f" -Root . -Path @(Get-Content {os.path.relpath(listing, ctx.root)})"
    source = f"pwsh {ctx.hub_display(script)}{selection} -JsonPath {os.path.relpath(out, ctx.root)}"
    args = ("PowerShell complexity findings", "findings", LOWER, CODE, source)
    name = "powershell_complexity_findings"
    if not files:
        return Metric(name, 0, "findings", LOWER, CODE, "no tracked PowerShell files")
    pwsh = shutil.which("pwsh")
    if pwsh is None:
        return failed(name, *args[1:], "pwsh is not on PATH")
    with open(listing, "w", encoding="utf-8") as fh:
        fh.write("".join(f"{rel}\n" for rel in files))
    command = f"& {ps_quote(os.path.join(ctx.tools, script))} -JsonPath {ps_quote(out)}"
    if not ctx.tools_are_root():
        command += f" -Root {ps_quote(ctx.root)} -Path @(Get-Content -LiteralPath {ps_quote(listing)})"
    rc, reason = run([pwsh, "-NoProfile", "-NonInteractive", "-Command", command], ctx.root,
                     os.path.join(ctx.work, "powershell-complexity.log"))
    try:
        if rc != 0:
            raise ValueError(f"exit {rc}: {reason}")
        doc = load_json(out)
        findings = doc.get("Findings")
        rows = [findings] if isinstance(findings, dict) else findings
        if not isinstance(rows, list) or not isinstance(doc.get("FindingCount"), int):
            raise TypeError("complexity JSON has no Findings list or FindingCount")
        items = [Item(str(f["File"]).replace("\\", "/"), int(f["Line"]), float(f["Actual"]),
                      f"{f['Name']} {f['Metric']}={f['Actual']} (limit {f['Limit']})")
                 for f in rows if isinstance(f, dict)]
        return Metric(name, int(str(doc["FindingCount"])), "findings", LOWER, CODE, source,
                      items=items)
    except (KeyError, TypeError, ValueError) as exc:
        return failed(name, *args[1:], str(exc))


def ps_quote(text: str) -> str:
    """A PowerShell single-quoted literal."""
    return "'" + text.replace("'", "''") + "'"
