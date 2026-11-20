"""Share exact-source CI inputs and durable evidence writes; this does not prove image or hardware execution."""

import hashlib
import json
import re
import subprocess
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from host_commands import checked_output

WORKFLOWS = ("linux-x64.yml", "windows-x64.yml", "docs.yml", "renovate-entrypoint.yml", "security-audit.yml")
DEFAULT_REPO = "Kataglyphis/ANTfrastructure"


def require(condition: object, message: str) -> None:
    if not condition:
        raise ValueError(message)


def read(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def save(path: Path, value: Any) -> None:
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")


def fingerprint(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def timestamp() -> str:
    return datetime.now(UTC).isoformat()


def gh(*args: str) -> Any:
    return json.loads(checked_output(["gh", *args], timeout=60))


def git(root: Path, *args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(root), *args], timeout=30)


def dispatch_record(path: Path) -> dict[str, Any]:
    plan = read(path)
    require(re.fullmatch(r"[0-9a-f]{40}", plan["source_revision"]), "Source must be a full SHA")
    rows = plan["workflows"]
    require(len(rows) == len(WORKFLOWS) and {row["file"] for row in rows} == set(WORKFLOWS), "Incomplete workflow set")
    ids = [row["run_id"] for row in rows]
    require(all(type(value) is int and value > 0 for value in ids) and len(set(ids)) == len(ids), "Invalid or duplicate run IDs")
    return plan


def successful_run(run: dict[str, Any], plan: dict[str, Any], workflow: str, run_id: int) -> None:
    require((run["id"], run["head_sha"], run["head_branch"], run["event"], run["status"], run["conclusion"])
            == (run_id, plan["source_revision"], plan["branch"], "workflow_dispatch", "completed", "success"),
            "Run identity differs or has not passed")
    require(run["path"].split("@", 1)[0] == ".github/workflows/" + workflow, "Workflow identity differs")


def job_list(path: Path, run_id: int, head: str) -> list[dict[str, Any]]:
    value = read(path)
    jobs = value["jobs"]
    require(len(jobs) == value["total_count"] > 0, "Incomplete job page")
    require(len({job["id"] for job in jobs}) == len(jobs), "Duplicate jobs")
    for job in jobs:
        require((job["run_id"], job["head_sha"], job["status"]) == (run_id, head, "completed"), "Job identity or status differs")
    return jobs
