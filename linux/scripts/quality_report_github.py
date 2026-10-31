# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Same-SHA lane artifacts and the previous develop record through the GitHub CLI.
It reads public run metadata only and never retries; see docs/code-quality-tooling.md#quality-report"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from fnmatch import fnmatch

MEASUREMENTS_ARTIFACT = "code-quality-measurements"


class Unavailable(Exception):
    """The lookup cannot run here (no gh, no login, no repository): the metric is not collected."""


class Broken(Exception):
    """The lookup ran and failed, or a found artifact could not be read: the verdict is incomplete."""


def repo_slug(root: str) -> str | None:
    """owner/name from GITHUB_REPOSITORY or the origin remote."""
    if os.environ.get("GITHUB_REPOSITORY"):
        return os.environ["GITHUB_REPOSITORY"]
    out = subprocess.run(["git", "-C", root, "remote", "get-url", "origin"],
                         capture_output=True, text=True, check=False)
    match = re.search(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$", out.stdout.strip())
    return match.group(1) if match else None


def _gh() -> str:
    gh = shutil.which("gh")
    if gh is None:
        raise Unavailable("the GitHub CLI is not on PATH")
    if not (os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")):
        status = subprocess.run([gh, "auth", "token"], capture_output=True, text=True,
                                check=False, stdin=subprocess.DEVNULL)
        if status.returncode != 0:
            raise Unavailable("the GitHub CLI has no login and no GH_TOKEN is set")
    return gh


def api(path: str) -> dict[str, object]:
    """One GET through gh api; any failure is Broken."""
    proc = subprocess.run([_gh(), "api", "-X", "GET", path], capture_output=True, text=True,
                          check=False, stdin=subprocess.DEVNULL)
    if proc.returncode != 0:
        raise Broken(f"gh api {path}: {proc.stderr.strip()[-300:]}")
    try:
        doc = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise Broken(f"gh api {path} returned no JSON: {exc}") from None
    if not isinstance(doc, dict):
        raise Broken(f"gh api {path} returned no JSON object")
    return doc


def download(slug: str, run_id: int, name: str, dest: str) -> None:
    """Fetch one artifact of one run into dest; a failure is Broken."""
    os.makedirs(dest, exist_ok=True)
    proc = subprocess.run([_gh(), "run", "download", str(run_id), "-R", slug, "-n", name,
                           "-D", dest], capture_output=True, text=True, check=False,
                          stdin=subprocess.DEVNULL)
    if proc.returncode != 0:
        shutil.rmtree(dest, ignore_errors=True)
        raise Broken(f"gh run download {run_id} -n {name}: {proc.stderr.strip()[-300:]}")


def _list(doc: dict[str, object], key: str) -> list[dict[str, object]]:
    rows = doc.get(key)
    if not isinstance(rows, list):
        raise Broken(f"GitHub answer has no `{key}` list")
    return [row for row in rows if isinstance(row, dict)]


def same_sha_artifact(slug: str, sha: str, pattern: str, workflow: str | None,
                      dest: str) -> str:
    """Download the newest artifact named like `pattern` from a run at `sha`; returns its directory."""
    runs = _list(api(f"repos/{slug}/actions/runs?head_sha={sha}&per_page=100"), "workflow_runs")
    for run in runs:
        if workflow and os.path.basename(str(run.get("path", "")).split("@")[0]) != workflow:
            continue
        run_id = int(str(run["id"]))
        found = _list(api(f"repos/{slug}/actions/runs/{run_id}/artifacts?per_page=100"),
                      "artifacts")
        for artifact in found:
            name = str(artifact.get("name", ""))
            if fnmatch(name, pattern) and not artifact.get("expired"):
                target = os.path.join(dest, f"{run_id}-{re.sub(r'[^\w.-]', '_', name)}")
                # Several declared sources may share one artifact; the first fetch serves them all.
                if not os.path.isdir(target):
                    download(slug, run_id, name, target)
                return target
    raise Unavailable(f"no run at {sha[:12]} carries an artifact named {pattern}")


def previous_develop(slug: str, dest: str) -> tuple[str, str]:
    """The newest code-quality-measurements artifact of a successful develop run, not this one."""
    current = os.environ.get("GITHUB_RUN_ID", "")
    doc = api(f"repos/{slug}/actions/artifacts?name={MEASUREMENTS_ARTIFACT}&per_page=100")
    rows = sorted(_list(doc, "artifacts"), key=lambda a: str(a.get("created_at", "")),
                  reverse=True)
    for artifact in rows:
        run = artifact.get("workflow_run")
        if not isinstance(run, dict) or artifact.get("expired"):
            continue
        run_id = str(run.get("id", ""))
        if run.get("head_branch") != "develop" or run_id in ("", current):
            continue
        if api(f"repos/{slug}/actions/runs/{run_id}").get("conclusion") != "success":
            continue
        target = os.path.join(dest, f"previous-develop-{run_id}")
        download(slug, int(run_id), MEASUREMENTS_ARTIFACT, target)
        path = os.path.join(target, "measurements.json")
        if not os.path.isfile(path):
            raise Broken(f"run {run_id}'s {MEASUREMENTS_ARTIFACT} artifact has no measurements.json")
        return path, f"run {run_id} at {str(run.get('head_sha', ''))[:12]}"
    raise Unavailable(f"no successful develop run carries {MEASUREMENTS_ARTIFACT} yet")
