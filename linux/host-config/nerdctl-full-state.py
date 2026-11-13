#!/usr/bin/env python3
"""Save rootless stack, image and cache identities before or after a full-bundle upgrade."""

from __future__ import annotations

import argparse
import collections
import datetime
import json
import os
import shutil
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path)
args = parser.parse_args()
args.directory.mkdir(parents=True, exist_ok=False)
environment = dict(os.environ, LC_ALL="C", BUILDKIT_HOST=f"unix:///run/user/{os.getuid()}/buildkit/buildkitd.sock")


def capture(name: str, command: list[str]) -> str:
    result = subprocess.run(command, env=environment, text=True, capture_output=True, timeout=90, check=False)
    (args.directory / f"{name}.stdout").write_text(result.stdout)
    (args.directory / f"{name}.stderr").write_text(result.stderr)
    if result.returncode:
        raise RuntimeError(f"{name} failed with status {result.returncode}: {result.stderr[:400]}")
    return result.stdout


records = json.loads(capture("buildkit-du", ["buildctl", "du", "--format", "{{json .}}"] ))
raw_images = capture("images", ["nerdctl", "images", "--digests", "--no-trunc", "--format", "{{json .}}"])
images = [json.loads(line) for line in raw_images.splitlines() if line.strip()]
running = capture("running-containers", ["nerdctl", "ps", "--format", "{{json .}}"])
capture("buildkit-info", ["buildctl", "debug", "info"])
capture("buildkit-workers", ["buildctl", "debug", "workers"])
capture("containerd-info", ["nerdctl", "info"])
capture("services", ["systemctl", "--user", "show", "containerd.service", "buildkit.service", "--property=Id,LoadState,ActiveState,SubState,MainPID,ExecStart,DropInPaths"])
versions = {}
for tool in ["nerdctl", "containerd", "buildkitd", "buildctl", "runc", "rootlesskit"]:
    versions[tool] = {"path": shutil.which(tool), "version": capture(f"version-{tool}", [tool, "--version"]).strip()}
types = collections.defaultdict(lambda: {"records": 0, "bytes": 0, "in_use": 0})
for record in records:
    item = types[record.get("recordType", "regular")]
    item["records"] += 1
    item["bytes"] += record["size"]
    item["in_use"] += int(record.get("inUse", False))
snapshot = {
    "observed_at": datetime.datetime.now(datetime.UTC).isoformat(),
    "buildkit_host": environment["BUILDKIT_HOST"],
    "versions": versions,
    "cachemount_ids": sorted(record["id"] for record in records if record.get("recordType") == "exec.cachemount"),
    "image_records": images,
    "running_containers": [json.loads(line) for line in running.splitlines() if line.strip()],
    "buildkit_record_types": dict(types),
    "disk_free_bytes": shutil.disk_usage(Path.home()).free,
    "reclaim_performed": False,
}
(args.directory / "snapshot.json").write_text(json.dumps(snapshot, indent=2) + chr(10))
print(json.dumps({"directory": str(args.directory), "image_records": len(images), "cachemounts": len(snapshot["cachemount_ids"]), "running_containers": len(snapshot["running_containers"]), "record_types": dict(types)}))
