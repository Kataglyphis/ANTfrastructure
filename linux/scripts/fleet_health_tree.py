# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Checkouts, quality-report tree metrics and the shared-facts check for fleet-health.
It measures the tree it is given and does not build or test it; see docs/fleet-health.md#running-it"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tomllib
from dataclasses import dataclass
from typing import Any

from fleet_health_github import (
    CODE,
    COLLECTED,
    FAILED,
    LOWER,
    NOT_COLLECTED,
    Metrics,
    gap,
    rec,
)

HUB_GITLINK = "third_party/ANTfrastructure"
QUALITY_TIMEOUT = 1800
CLONE_URL = "https://github.com/Kataglyphis/{repo}.git"
SHARED_REPOS = ("OxidANT", "AccelerANTgine", "OrchestrANT")
SHARED_LOCKS = (
    ("shared_facts.models_lock_deim", "models.lock", "DEIM", lambda name: name.startswith("deim_")),
    ("shared_facts.llm_lock_smollm2", "llm.lock", "SmolLM2", lambda name: "smollm2" in name.lower()),
)


@dataclass
class Checkout:
    """One repository's tree as this run measures it; error set means it was refused."""

    repo: str
    path: str
    sha: str = ""
    error: str = ""

    def exists(self, rel: str) -> bool:
        return os.path.lexists(os.path.join(self.path, rel))


def git(path: str, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", "-C", path, *args], capture_output=True, text=True,
                          check=False, stdin=subprocess.DEVNULL)


def local_checkout(root: str, repo: str) -> Checkout:
    """DIR/<repo> at its SHA; a missing, dirty or behind-origin/develop checkout is refused."""
    co = Checkout(repo, os.path.join(root, repo))
    head = git(co.path, "rev-parse", "--show-toplevel", "HEAD")
    top = head.stdout.split()
    if head.returncode != 0 or len(top) != 2 or not os.path.samefile(top[0], co.path):
        co.error = f"missing checkout: {co.path} is not a Git checkout"
        return co
    co.sha = top[1]
    status = git(co.path, "status", "--porcelain", "--ignore-submodules=dirty")
    if status.returncode != 0 or status.stdout.strip():
        co.error = f"dirty checkout: {co.path} has uncommitted changes"
        return co
    if git(co.path, "fetch", "--quiet", "origin", "develop").returncode != 0:
        co.error = f"stale checkout: cannot fetch origin develop into {co.path}"
        return co
    behind = git(co.path, "rev-list", "--count", "HEAD..FETCH_HEAD").stdout.strip()
    if behind != "0":
        co.error = f"stale checkout: {co.path} is {behind or 'an unknown number of'} commit(s) behind origin/develop"
    return co


def clone_checkout(work: str, repo: str, url: str) -> Checkout:
    """A fresh clone of the develop tip with its direct submodules, as the repo's own report job checks out."""
    co = Checkout(repo, os.path.join(work, repo))
    shutil.rmtree(co.path, ignore_errors=True)
    steps = (["git", "clone", "--quiet", "--branch", "develop", url.format(repo=repo), co.path],
             ["git", "-C", co.path, "submodule", "update", "--init", "--quiet"])
    for cmd in steps:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False,
                              stdin=subprocess.DEVNULL)
        if proc.returncode != 0:
            co.error = f"clone failed: {' '.join(cmd[:4])}: {proc.stderr.strip()[-300:]}"
            return co
    co.sha = git(co.path, "rev-parse", "HEAD").stdout.strip()
    return co


def hub_pin(co: Checkout) -> str | None:
    """The checkout's third_party/ANTfrastructure gitlink, if it has one."""
    out = git(co.path, "ls-tree", "HEAD", HUB_GITLINK).stdout.split()
    return out[2] if len(out) >= 3 and out[0] == "160000" else None


def config(co: Checkout) -> dict[str, Any]:
    """quality-report.toml, or nothing; quality-report itself grades a malformed one."""
    try:
        with open(os.path.join(co.path, "quality-report.toml"), "rb") as fh:
            return tomllib.load(fh)
    except (OSError, tomllib.TOMLDecodeError):
        return {}


def benchmark_keys(conf: dict[str, Any]) -> list[str]:
    """The bench-history artifacts the repo's [[output]] rows declare."""
    rows = conf.get("output", [])
    return sorted({str(r["artifact"]) for r in rows if isinstance(r, dict)
                   and r.get("kind") == "benchmark" and isinstance(r.get("artifact"), str)})


def artifact_names(conf: dict[str, Any], names: list[str]) -> set[str]:
    """Metric names that come from [[artifact]] rows: `<suffix>.<row>` or the bare row name."""
    rows = {str(r["name"]) for r in conf.get("artifact", []) if isinstance(r, dict) and "name" in r}
    return {n for n in names if n in rows or any(n.endswith("." + row) for row in rows)}


def report_command(co: Checkout) -> list[str] | None:
    """The repo's own quality-report entry: its wrapper, the hub's script, or its pinned hub's."""
    for rel, extra in (("scripts/linux/quality-report.sh", []),
                       ("linux/scripts/quality-report.sh", ["--root", "."]),
                       (f"{HUB_GITLINK}/linux/scripts/quality-report.sh", ["--root", "."])):
        if os.path.isfile(os.path.join(co.path, rel)):
            return ["bash", rel, *extra, "--offline"]
    return None


def tree_metrics(co: Checkout) -> tuple[Metrics, str]:
    """(metrics, command) from the checkout's quality-report.sh run offline; a broken run is one failed metric."""
    cmd = report_command(co)
    if cmd is None:
        return {"quality_report": gap(NOT_COLLECTED, "", LOWER, CODE, "quality-report.sh",
                                      "the checkout has no quality-report.sh")}, ""
    out = os.path.join(co.path, "logs", "code-quality", "measurements.json")
    if os.path.exists(out):
        os.remove(out)
    shown = " ".join(cmd)
    try:
        proc = subprocess.run(cmd, cwd=co.path, capture_output=True, text=True, check=False,
                              stdin=subprocess.DEVNULL, timeout=QUALITY_TIMEOUT)
        with open(out, encoding="utf-8") as fh:
            doc = json.load(fh)
        if proc.returncode not in (0, 1, 2) or doc.get("sha") != co.sha:
            raise ValueError(f"exit {proc.returncode}, record sha {str(doc.get('sha'))[:12]}")
        metrics = doc["metrics"]
        if not isinstance(metrics, dict):
            raise TypeError("measurements.json has no metrics table")
    except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as exc:
        return {"quality_report": gap(FAILED, "", LOWER, CODE, shown, f"{shown}: {exc}")}, shown
    return {name: {**row, "source": row.get("source", shown)} for name, row in metrics.items()}, shown


def overlay(metrics: Metrics, names: set[str], lane: Metrics | None, where: str) -> Metrics:
    """Artifact metrics from the same-SHA lane record; absent there, they stay not collected."""
    for name in sorted(names):
        row = (lane or {}).get(name)
        if not isinstance(row, dict):
            metrics[name] = {**metrics[name], "status": NOT_COLLECTED, "value": None,
                             "reason": where if lane is None else f"{where} has no {name}"}
        elif row.get("status", COLLECTED) == COLLECTED:
            metrics[name] = {**row, "source": f"{row.get('source', '')} ({where})"}
        else:
            reason = f"{where} marks it {row.get('status')}: {row.get('reason', '')}"
            metrics[name] = {**row, "status": NOT_COLLECTED, "value": None, "reason": reason}
    return metrics


def lock_rows(co: Checkout, lock: str, wanted: Any) -> list[str] | None:
    """The selected `sha256 file url` rows of the repo's tracked <lock> files, or None without one."""
    files = git(co.path, "ls-files", "--", f":(glob)**/{lock}", ":(exclude)third_party").stdout.split()
    if not files:
        return None
    rows: list[str] = []
    for rel in sorted(files):
        with open(os.path.join(co.path, rel), encoding="utf-8") as fh:
            for line in fh:
                cols = line.split()
                if len(cols) >= 3 and not cols[0].startswith("#") and wanted(cols[1]):
                    rows.append(" ".join(cols[:3]))
    return sorted(rows)


def shared_facts(checkouts: dict[str, Checkout]) -> Metrics:
    """How many row sets beyond one the shared model rows take across the three repos; 0 means they agree."""
    metrics: Metrics = {}
    for name, lock, label, wanted in SHARED_LOCKS:
        source = f"{label} rows of {lock} in {', '.join(SHARED_REPOS)}"
        unmeasured = [r for r in SHARED_REPOS if r not in checkouts or checkouts[r].error]
        if unmeasured:
            metrics[name] = gap(NOT_COLLECTED, "row sets", LOWER, CODE, source,
                                f"not measured in this run: {', '.join(unmeasured)}")
            continue
        found = {r: lock_rows(checkouts[r], lock, wanted) for r in SHARED_REPOS}
        absent = [r for r, rows in found.items() if rows is None]
        if absent:
            present = ", ".join(f"{r} ({len(rows or [])} rows)" for r, rows in found.items() if rows is not None)
            metrics[name] = gap(NOT_COLLECTED, "row sets", LOWER, CODE, source,
                                f"{lock} absent in {', '.join(absent)}; present in {present or 'none'}")
            continue
        variants = {tuple(rows or []) for rows in found.values()}
        metrics[name] = {**rec(len(variants) - 1, "row sets", LOWER, CODE, source),
                         "detail": {r: rows for r, rows in found.items()}}
    return metrics
