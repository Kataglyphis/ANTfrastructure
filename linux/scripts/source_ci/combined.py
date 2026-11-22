"""Join exact five-workflow source evidence; inference, images and finished packages remain unproved."""

import argparse
import re
from pathlib import Path
from typing import Any

from source_ci.common import (
    dispatch_record,
    fingerprint,
    job_list,
    read,
    require,
    save,
    successful_run,
    timestamp,
)


def workflow_logs(row: dict[str, Any], plan: dict[str, Any], directory: Path) -> dict[str, Any]:
    run_id = row["run_id"]
    run = read(directory / f"run-{run_id}.json")
    successful_run(run, plan, row["file"], run_id)
    logs, skipped = [], []
    for job in job_list(directory / f"jobs-{run_id}.json", run_id, plan["source_revision"]):
        if job["conclusion"] == "skipped":
            require(row["file"] == "docs.yml" and job["name"] == "docs / Publish the site", "Unexpected skipped job")
            skipped.append(job["name"])
            continue
        require(job["conclusion"] == "success", "A source job failed")
        path = directory / f"source-ci-{job['id']}.log"
        require(path.stat().st_size > 0, "Empty source log")
        if row["file"] == "security-audit.yml":
            require(re.search(r"security-audit: .*mode gate", path.read_text(encoding="utf-8")), "Security workflow did not run gate mode")
        logs.append({"job": job["name"], "file": str(path), "sha256": fingerprint(path)})
    require(logs, "Workflow has no successful executed jobs")
    return {"run": run_id, "name": run["name"], "attempt": run["run_attempt"], "logs": logs, "expected_skipped": skipped}


def verify_subproofs(args: argparse.Namespace, plan: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    linux, windows = read(args.linux), read(args.windows)
    require(linux["head"] == windows["head"] == plan["source_revision"], "Subproof source differs")
    require(all(linux[key] == 0 for key in ("missing", "extra", "duplicates", "delegated", "skipped")), "Linux coverage incomplete")
    require(not any(windows[key] for key in ("failed", "skipped", "broken", "coverage_failures")), "Native Windows verdict failed")
    runs = {row["file"]: row["run_id"] for row in plan["workflows"]}
    require(linux["run_id"] == runs["linux-x64.yml"] and windows["run_id"] == runs["windows-x64.yml"], "Subproof run differs")
    require(linux["run_attempt"] == read(args.directory / f"run-{linux['run_id']}.json")["run_attempt"], "Linux attempt differs")
    for row in [*linux["mutation_jobs"], linux["preflight"]]:
        job_id = row.get("id", row.get("job_id"))
        require(fingerprint(args.directory / f"source-ci-{job_id}.log") == row["log_sha256"], "Audited Linux log changed")
    require("sha256:" + fingerprint(args.directory / "windows-artifact.zip") == windows["digest"], "Audited Windows archive changed")
    return linux, windows


def run(args: argparse.Namespace) -> None:
    plan = dispatch_record(args.dispatch)
    linux, windows = verify_subproofs(args, plan)
    rows = [workflow_logs(row, plan, args.directory) for row in plan["workflows"]]
    proof = {"status": "passed-five-source-ci-only", "observed_at": timestamp(), "head": plan["source_revision"],
             "runs": rows, "linux_unique_mutations": linux["unique_ids"], "linux_suites": linux["preflight"]["suites"],
             "linux_assertions": linux["preflight"]["assertions"], "native_windows_tests": windows["total"],
             "native_windows_coverage_floors": len(windows["coverage"]), "security_mode": "gate", "scope_limits": [__doc__],
             "audit_inputs": {str(path): fingerprint(path) for path in (args.dispatch, args.linux, args.windows)}}
    save(args.output, proof)
