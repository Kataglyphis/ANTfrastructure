"""Dispatch once or reuse one existing source run; an interrupted dispatch must be resolved manually."""

import argparse
import json
import os
import re
from pathlib import Path
from typing import Any, TextIO
from urllib.parse import quote

from host_commands import checked_output
from source_ci.common import WORKFLOWS, gh, require, timestamp


def checkpoint(stream: TextIO, plan: dict[str, Any]) -> None:
    stream.seek(0)
    stream.write(json.dumps(plan, indent=2) + "\n")
    stream.truncate()
    stream.flush()
    os.fsync(stream.fileno())


def check_remote(repo: str, branch: str, head: str) -> None:
    remote = gh("api", f"repos/{repo}/git/ref/heads/{quote(branch, safe='')}")
    require(remote["object"]["sha"] == head, "Remote branch differs from requested source")


def workflow_run(repo: str, args: argparse.Namespace, workflow: str, stream: TextIO, plan: dict[str, Any]) -> None:
    existing = gh("run", "list", "-R", repo, "--workflow", workflow, "--commit", args.head,
                  "--event", "workflow_dispatch", "--limit", "20", "--json",
                  "databaseId,headSha,headBranch,workflowName,status,conclusion")
    matching = [run for run in existing if run["headSha"] == args.head and run["headBranch"] == args.branch]
    require(len(matching) <= 1, f"Multiple existing runs for {workflow}; inspect them")
    row: dict[str, Any] = {"file": workflow, "reused": bool(matching)}
    plan["workflows"].append(row)
    if matching:
        row.update(state="reused-existing-run", run_id=matching[0]["databaseId"])
    else:
        check_remote(repo, args.branch, args.head)
        row["state"] = "dispatching-once-do-not-repeat-if-interrupted"
        checkpoint(stream, plan)
        command = ["gh", "workflow", "run", workflow, "-R", repo, "--ref", args.branch]
        if workflow == "security-audit.yml":
            command.extend(["-f", "mode=gate"])
        output = checked_output(command, timeout=60)
        row.update(state="dispatched-run-id-unresolved-do-not-repeat", dispatch_stdout=output)
        checkpoint(stream, plan)
        match = re.search(r"/actions/runs/(\d+)", output)
        if match is None:
            raise ValueError(f"Resolve {workflow}'s run ID without dispatching again")
        row.update(state="dispatched-once", run_id=int(match[1]))
    checkpoint(stream, plan)
    print(f"{workflow}: {row['state']} {row['run_id']}", flush=True)


def run(args: argparse.Namespace) -> None:
    require(re.fullmatch(r"[0-9a-f]{40}", args.head), "Source must be a full SHA")
    check_remote(args.repo, args.branch, args.head)
    plan = {"repository": args.repo, "source_revision": args.head, "branch": args.branch,
            "started_at": timestamp(), "workflows": []}
    with Path(args.output).open("x", encoding="utf-8") as stream:
        checkpoint(stream, plan)
        for workflow in WORKFLOWS:
            workflow_run(args.repo, args, workflow, stream, plan)
        check_remote(args.repo, args.branch, args.head)
