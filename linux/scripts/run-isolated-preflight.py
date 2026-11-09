#!/usr/bin/env python3
"""Run the complete preflight from a preserved commit snapshot in a disposable Ubuntu container."""

import argparse
import datetime
import hashlib
import json
import re
import shutil
import signal
import subprocess
import sys
import uuid
from pathlib import Path

from host_commands import checked_output, run_logged

ROOT = Path(__file__).resolve().parents[2]
BOOTSTRAP = Path("linux/scripts/isolated-preflight/bootstrap.sh")
OWNER_LABEL = "org.kataglyphis.isolated-preflight"


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", default="HEAD")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--memory", default="12g")
    parser.add_argument("--engine", default=shutil.which("nerdctl") or shutil.which("docker") or "nerdctl")
    args = parser.parse_args()
    if args.jobs < 1 or not re.fullmatch(r"[1-9][0-9]*[kmg]", args.memory):
        parser.error("jobs must be positive and memory must use a positive k/m/g quantity")
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*", args.name):
        parser.error("name must be a plain container name")
    args.output = args.output.resolve()
    return args


def git(*args: str) -> str:
    return checked_output(["git", "-C", str(ROOT), *args], timeout=120).strip()


def freeze_source(revision: str, output: Path) -> tuple[Path, str]:
    sha = git("rev-parse", "--verify", f"{revision}^{{commit}}")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("revision did not resolve to a full commit")
    if output.exists():
        raise ValueError(f"output already exists; preserve it and choose a new run directory: {output}")
    output.mkdir(parents=True)
    source = output / "source"
    checked_output(["git", "-c", "core.autocrlf=false", "clone", "--quiet", "--no-local", "--no-checkout", str(ROOT), str(source)], timeout=180)
    checked_output(["git", "-C", str(source), "checkout", "--quiet", "--detach", sha], timeout=120)
    checked_output(["git", "-C", str(source), "remote", "set-url", "origin", "https://github.com/Kataglyphis/ANTfrastructure.git"])
    if not (source / BOOTSTRAP).is_file():
        raise ValueError("the selected commit predates the permanent isolated-preflight scripts")
    return source, sha


def base_image(source: Path) -> str:
    loader = source / "linux/scripts/01-core/load-versions-env.sh"
    pins = source / "linux/scripts/01-core/versions.env"
    command = 'source "$1"; unset UBUNTU_VERSION UBUNTU_DIGEST; load_versions_env "$2"; printf "%s\\n%s\\n" "$UBUNTU_VERSION" "$UBUNTU_DIGEST"'
    version, digest = checked_output(["bash", "-euo", "pipefail", "-c", command, "preflight-pins", str(loader), str(pins)]).splitlines()
    if not re.fullmatch(r"[0-9]+\.[0-9]+", version) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ValueError("the snapshot has no valid pinned Ubuntu base")
    return f"docker.io/library/ubuntu:{version}@{digest}"


def container_args(args: argparse.Namespace, source: Path, reports: Path, sha: str, image: str, run_id: str) -> list[str]:
    return [args.engine, "run", "--name", args.name, "--cidfile", str(args.output / "container.cid"),
            "--label", f"{OWNER_LABEL}={run_id}", "--pull", "never", "--security-opt", "apparmor=unconfined",
            "--cpus", str(args.jobs), "--memory", args.memory, "--shm-size", "1g", "--user", "0:0",
            "--entrypoint", "/bin/bash", "--env", f"ISOLATED_PREFLIGHT_REVISION={sha}",
            "--env", f"ISOLATED_PREFLIGHT_JOBS={args.jobs}",
            "-v", f"{source}:/source:ro", "-v", f"{reports}:/evidence", image, f"/source/{BOOTSTRAP}"]


def interrupted(signum: int, _frame: object) -> None:
    raise SystemExit(128 + signum)


def cleanup(engine: str, run_id: str, reports: Path) -> int:
    try:
        owned = checked_output([engine, "ps", "-a", "--no-trunc", "--filter",
                                f"label={OWNER_LABEL}={run_id}", "--format", "{{.ID}}"])
        status = 0
        for container_id in owned.splitlines():
            if not re.fullmatch(r"[0-9a-f]{64}", container_id):
                raise ValueError("the engine returned an invalid owned container ID")
            result = subprocess.run([engine, "rm", "--force", container_id], timeout=60, check=False)
            status = status or result.returncode
        return status
    finally:
        reports.chmod(0o755)


def run(args: argparse.Namespace) -> int:
    source, sha = freeze_source(args.revision, args.output)
    image = base_image(source)
    run_id = uuid.uuid4().hex
    reports = args.output / "reports"
    reports.mkdir()
    reports.chmod(0o777)
    record = {"status": "running", "source_revision": sha, "source_snapshot": str(source),
              "image": image, "container": args.name, "owner_run_id": run_id, "jobs": args.jobs, "memory": args.memory,
              "started_at": datetime.datetime.now(datetime.UTC).isoformat(),
              "bootstrap_sha256": hashlib.sha256((source / BOOTSTRAP).read_bytes()).hexdigest()}
    metadata = args.output / "run.json"
    metadata.write_text(json.dumps(record, indent=2) + "\n")
    status = 1
    cleaned = 1
    try:
        inspect = subprocess.run([args.engine, "image", "inspect", image], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False, timeout=30)
        if inspect.returncode:
            checked_output([args.engine, "pull", image], timeout=1800)
        status = run_logged(container_args(args, source, reports, sha, image, run_id), args.output / "preflight.log")
    finally:
        try:
            cleaned = cleanup(args.engine, run_id, reports)
            if status == 0 and not (args.output / "container.cid").is_file():
                cleaned = 1
        finally:
            record.update({"status": "passed" if status == 0 and cleaned == 0 else "failed",
                           "command_exit_status": status, "cleanup_exit_status": cleaned,
                           "finished_at": datetime.datetime.now(datetime.UTC).isoformat()})
            metadata.write_text(json.dumps(record, indent=2) + "\n")
    return status if status else int(cleaned != 0)


def main() -> int:
    args = arguments()
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, interrupted)
    return run(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"run-isolated-preflight: {error}", file=sys.stderr)
        sys.exit(2)
