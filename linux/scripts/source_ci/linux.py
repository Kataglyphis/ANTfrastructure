"""Audit exact Linux mutation union and preflight logs; other platforms, packages and GPUs remain separate proofs."""

import argparse
import collections
import hashlib
import json
import re
from pathlib import Path
from typing import Any

from source_ci.common import git, job_list, read, require, save, timestamp


def mutation_log(job: dict[str, Any], directory: Path, binding: dict[str, Any], total: int) -> tuple[dict[str, Any], list[str]]:
    path = directory / f"source-ci-{job['id']}.log"
    raw = path.read_bytes()
    text = raw.decode()
    require(binding["merge_checkout"] in text, "Mutation log lacks its checkout identity")
    ids = re.findall(r"^\ufeff?\S+\s+\[\d+/\d+\]\s+bites\s+(\S+)", text, re.MULTILINE)
    coverage = re.findall(r"coverage: proved (\d+) of (\d+) selected; (\d+) delegated to CI, (\d+) skipped by this host; the manifest holds (\d+)", text)
    require(len(coverage) == 1, "Missing or ambiguous mutation coverage")
    proved, selected, delegated, skipped, reported_total = map(int, coverage[0])
    require(proved == selected == len(ids) and proved > 0 and delegated == skipped == 0 and reported_total == total,
            "Mutation coverage is incomplete or skipped")
    require(len(ids) == len(set(ids)) and "FAIL:" not in text, "Duplicate mutations or failures")
    return {"id": job["id"], "name": job["name"], "proved": proved, "log": str(path),
            "log_sha256": hashlib.sha256(raw).hexdigest()}, ids


def preflight_log(job: dict[str, Any], directory: Path, binding: dict[str, Any]) -> dict[str, Any]:
    path = directory / f"source-ci-{job['id']}.log"
    raw = path.read_bytes()
    text = raw.decode()
    require(binding["merge_checkout"] in text and "All preflight checks passed." in text, "Preflight did not prove the source passed")
    summaries = re.findall(r"All linux script test suites passed \((\d+) suites, (\d+) assertions\)", text)
    require(len(summaries) == 1 and all(int(value) > 0 for value in summaries[0]), "Missing or vacuous script summary")
    suites, assertions = map(int, summaries[0])
    return {"job_id": job["id"], "suites": suites, "assertions": assertions, "log": str(path),
            "log_sha256": hashlib.sha256(raw).hexdigest()}


def run(args: argparse.Namespace) -> None:
    manifest = git(args.root, "show", args.head + ":docs/scripts/mutations.json")
    expected = [entry["id"] for entry in json.loads(manifest)]
    require(expected and len(expected) == len(set(expected)), "Empty manifest or duplicate source IDs")
    run_data = read(args.run)
    binding = read(args.tree_binding)
    require(binding["head"] == args.head and binding["head_merge_and_local_tree_match"], "Missing tree binding")
    require(binding["merge_checkout"] == args.head and binding["tree"] == git(args.root, "rev-parse", f"{args.head}^{{tree}}").decode().strip(),
            "Tested checkout or local tree differs")
    require((run_data["head_sha"], run_data["status"], run_data["conclusion"]) == (args.head, "completed", "success"), "Linux run has not passed")
    jobs = job_list(args.jobs, run_data["id"], args.head)
    names = {"preflight", "submodule-cycles", *(f"mutations ({index})" for index in range(8))}
    require(collections.Counter(job["name"] for job in jobs) == collections.Counter(names), "Linux job set changed")
    rows, all_ids = [], []
    for job in jobs:
        require(job["conclusion"] == "success", "A required Linux job failed")
        if job["name"].startswith("mutations ("):
            row, ids = mutation_log(job, args.log_dir, binding, len(expected))
            rows.append(row)
            all_ids.extend(ids)
    require(collections.Counter(all_ids) == collections.Counter(expected), "Mutation union has missing, extra or duplicate IDs")
    preflight = next(job for job in jobs if job["name"] == "preflight")
    proof = {"status": "passed-source-linux-ci-only", "observed_at": timestamp(), "scope": __doc__,
             "head": args.head, "merge_checkout": binding["merge_checkout"], "tree": binding["tree"],
             "run_id": run_data["id"], "run_attempt": run_data["run_attempt"], "manifest_sha256": hashlib.sha256(manifest).hexdigest(),
             "mutation_union": len(all_ids), "unique_ids": len(set(all_ids)), "missing": 0, "extra": 0,
             "duplicates": 0, "delegated": 0, "skipped": 0, "mutation_jobs": rows,
             "preflight": preflight_log(preflight, args.log_dir, binding)}
    save(args.output, proof)
