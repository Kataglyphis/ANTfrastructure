"""Preserve existing successful source runs and raw logs; downloads never dispatch or retry writes."""

import argparse
import json
import subprocess
from pathlib import Path
from typing import Any

from source_ci.common import (
    DEFAULT_REPO,
    dispatch_record,
    fingerprint,
    gh,
    git,
    job_list,
    read,
    require,
    save,
    successful_run,
)


def fetch(repo: str, endpoint: str, destination: Path, raw: bool = False) -> None:
    if destination.exists():
        require(destination.stat().st_size > 0, f"Empty preserved input: {destination}")
        return
    result = subprocess.run(["gh", "api", "--allow-escape-sequences", f"repos/{repo}/{endpoint}"],
                            capture_output=True, check=True, timeout=60)
    require(result.stdout, f"Empty download: {destination}")
    if not raw:
        json.loads(result.stdout)
    pending = destination.with_name(destination.name + ".download")
    with pending.open("xb") as stream:
        stream.write(result.stdout)
    try:
        destination.hardlink_to(pending)
    finally:
        pending.unlink()


def preserve_run(repo: str, plan: dict[str, Any], row: dict[str, Any], directory: Path) -> None:
    run_id = row["run_id"]
    run_path = directory / f"run-{run_id}.json"
    if not run_path.exists():
        value = gh("api", f"repos/{repo}/actions/runs/{run_id}")
        successful_run(value, plan, row["file"], run_id)
        save(run_path, value)
    successful_run(read(run_path), plan, row["file"], run_id)
    jobs_path = directory / f"jobs-{run_id}.json"
    attempt = read(run_path)["run_attempt"]
    fetch(repo, f"actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100", jobs_path)
    for job in job_list(jobs_path, run_id, plan["source_revision"]):
        require(job["conclusion"] in ("success", "skipped"), "A job failed")
        if job["conclusion"] != "skipped":
            fetch(repo, f"actions/jobs/{job['id']}/logs", directory / f"source-ci-{job['id']}.log", raw=True)
    print(f"Preserved {row['file']}: {run_id}", flush=True)


def bind_tree(repo: str, plan: dict[str, Any], root: Path, directory: Path) -> None:
    head = plan["source_revision"]
    fetch(repo, f"git/commits/{head}", directory / "remote-commit.json")
    remote = read(directory / "remote-commit.json")
    tree = git(root, "rev-parse", f"{head}^{{tree}}").decode().strip()
    require(remote["sha"] == head and remote["tree"]["sha"] == tree, "Remote and local trees differ")
    binding = {"head": head, "merge_checkout": head, "tree": tree, "head_merge_and_local_tree_match": True,
               "checkout_kind": "workflow_dispatch direct source head; no synthetic PR merge"}
    path = directory / "tree-binding.json"
    if path.exists():
        require(read(path) == binding, "Preserved tree binding differs")
    else:
        save(path, binding)


def windows_artifact(repo: str, plan: dict[str, Any], directory: Path) -> None:
    run_id = next(row["run_id"] for row in plan["workflows"] if row["file"] == "windows-x64.yml")
    path = directory / "windows-artifacts.json"
    fetch(repo, f"actions/runs/{run_id}/artifacts?per_page=100", path)
    listing = read(path)
    require(len(listing["artifacts"]) == listing["total_count"], "Incomplete artifact page")
    matches = [row for row in listing["artifacts"] if row["name"] == f"windows-x64-tests-{run_id}"]
    require(len(matches) == 1 and not matches[0]["expired"], "Missing or ambiguous Windows artifact")
    artifact = matches[0]
    require((artifact["workflow_run"]["id"], artifact["workflow_run"]["head_sha"])
            == (run_id, plan["source_revision"]), "Artifact source differs")
    api = directory / "windows-artifact-api.json"
    if api.exists():
        require(read(api) == artifact, "Preserved artifact metadata differs")
    else:
        save(api, artifact)
    archive = directory / "windows-artifact.zip"
    fetch(repo, f"actions/artifacts/{artifact['id']}/zip", archive, raw=True)
    require("sha256:" + fingerprint(archive) == artifact["digest"] and archive.stat().st_size == artifact["size_in_bytes"],
            "Artifact bytes differ from API metadata")


def run(args: argparse.Namespace) -> None:
    plan = dispatch_record(args.dispatch)
    repo = plan.get("repository", DEFAULT_REPO)
    args.directory.mkdir(exist_ok=True)
    for row in plan["workflows"]:
        preserve_run(repo, plan, row, args.directory)
    bind_tree(repo, plan, args.root, args.directory)
    windows_artifact(repo, plan, args.directory)
