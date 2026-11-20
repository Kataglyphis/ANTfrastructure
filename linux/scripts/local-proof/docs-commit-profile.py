#!/usr/bin/env python3
"""Commit or seal documentation with normal hooks and zero recipe targets; no CI or product acceptance is implied."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import re
import subprocess
from pathlib import Path

from proof_commands import command_bytes


def checked(command: list[str]) -> str:
    return subprocess.run(command, capture_output=True, text=True, check=True, timeout=60).stdout


def git_bytes(source: Path, *arguments: str) -> bytes:
    return command_bytes(["git", "-C", str(source), *arguments])


def git(source: Path, *arguments: str) -> str:
    return git_bytes(source, *arguments).decode()


def state(unit: str) -> dict[str, str]:
    fields = "Id,LoadState,ActiveState,SubState,MainPID,Result,ExecMainStatus,ExecMainExitTimestampMonotonic"
    raw = checked(["systemctl", "--user", "show", unit, "--property=" + fields])
    return dict(line.split("=", 1) for line in raw.splitlines() if "=" in line)


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + chr(10))


def launch(args: argparse.Namespace) -> None:
    source = args.source.resolve()
    assert (source / "AGENTS.md").read_text().startswith("# ANTfrastructure")
    assert git(source, "rev-parse", "--show-toplevel").strip() == str(source)
    assert args.paths and all(not Path(name).is_absolute() and ".." not in Path(name).parts and name.endswith(".md") for name in args.paths)
    assert re.fullmatch(r"webgpu-[A-Za-z0-9_.-]+\.service", args.unit)
    assert state(args.unit)["LoadState"] == "not-found" and not args.evidence.exists()
    git(source, "add", "--", *args.paths)
    paths = set(git(source, "diff", "--cached", "--name-only").splitlines())
    assert paths == set(args.paths) and not git(source, "diff", "--name-only").strip()
    recipes = json.loads((source / "docs/scripts/mutations.json").read_text())
    assert not any(row["target"] in paths for row in recipes), "Use the regular mutation sealer when staged recipes exist"
    cache = Path.home() / ".cache" / args.unit.removesuffix(".service")
    assert not cache.exists() and not any((parent / ".git").exists() for parent in (cache, *cache.parents))
    cache.mkdir()
    args.evidence.mkdir(parents=True)
    log = args.evidence / "commit.log"
    command = ["systemd-run", "--user", "--no-block", "--expand-environment=no", "--unit=" + args.unit]
    for prop in ("Type=oneshot", "RemainAfterExit=yes", "TimeoutStartSec=1200", "TimeoutStopSec=300", "KillMode=control-group", "WorkingDirectory=" + str(source), "StandardOutput=append:" + str(log), "StandardError=append:" + str(log)):
        command += ["-p", prop]
    for env in ("LC_ALL=C", f"HOME={Path.home()}", "TMPDIR=" + str(cache), f"PATH={Path.home()}/.local/bin:{Path.home()}/.cargo/bin:/usr/local/bin:/usr/bin:/bin"):
        command += ["-E", env]
    command += ["git", "-c", "user.name=Codex", "-c", "user.email=codex@local", "-c", "core.hooksPath=linux/host-config/git-hooks", "commit", "-m", args.message]
    record = {"created_at": datetime.datetime.now(datetime.UTC).isoformat(), "source": str(source), "unit": args.unit, "parent": git(source, "rev-parse", "HEAD").strip(), "files": sorted(paths), "patch_sha256": hashlib.sha256(git_bytes(source, "diff", "--cached", "--full-index", "--binary")).hexdigest(), "command": command, "staged_mutation_targets": 0, "publication": False}
    save(args.evidence / "invocation.json", record)
    result = subprocess.run(command, capture_output=True, text=True, check=False, timeout=60)
    record.update(launch_status=result.returncode, stdout=result.stdout, stderr=result.stderr)
    save(args.evidence / "invocation.json", record)
    assert result.returncode == 0
    print(json.dumps({"unit": args.unit, "launch_status": 0, "staged_mutation_targets": 0}))


def seal(args: argparse.Namespace) -> None:
    record = json.loads((args.evidence / "invocation.json").read_text())
    source = Path(record["source"])
    before = state(record["unit"])
    assert before["Id"] == record["unit"] and before["LoadState"] == "loaded"
    assert before["ActiveState"] == "active" and before["SubState"] == "exited" and before["Result"] == "success"
    assert before["MainPID"] == before["ExecMainStatus"] == "0" and int(before["ExecMainExitTimestampMonotonic"]) > 0
    assert git(source, "rev-parse", "HEAD^").strip() == record["parent"]
    assert hashlib.sha256(git_bytes(source, "diff", "--full-index", "--binary", "HEAD^", "HEAD")).hexdigest() == record["patch_sha256"]
    assert not git(source, "status", "--porcelain").strip()
    assert "pre-commit: OK" in (args.evidence / "commit.log").read_text()
    assert not (args.evidence / "proof.json").exists()
    proof = {"observed_at": datetime.datetime.now(datetime.UTC).isoformat(), "status": "passed-documentation-only", "head": git(source, "rev-parse", "HEAD").strip(), "parent": record["parent"], "files": record["files"], "terminal_before_stop": before, "patch_sha256": record["patch_sha256"], "exact_committed_patch_match": True, "normal_hook_status": 0, "staged_mutation_targets": 0, "actual_hook_mutations": 0, "mutation_proof_claimed": False, "clean": True, "publication": False}
    save(args.evidence / "proof.json", proof)
    checked(["systemctl", "--user", "stop", record["unit"]])
    after = state(record["unit"])
    assert after["ActiveState"] == "inactive" and after["MainPID"] == "0"
    proof["stopped"] = after
    save(args.evidence / "proof-stopped.json", proof)
    print(json.dumps({"head": proof["head"], "normal_hook_status": 0, "mutation_targets": 0, "stopped": True}))


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("mode", choices=("launch", "seal"))
parser.add_argument("--evidence", type=Path, required=True)
parser.add_argument("--source", type=Path)
parser.add_argument("--unit")
parser.add_argument("--message")
parser.add_argument("--path", action="append", dest="paths")
args = parser.parse_args()
args.evidence = args.evidence.resolve()
if args.mode == "launch":
    assert args.source and args.unit and args.message
    launch(args)
else:
    seal(args)
