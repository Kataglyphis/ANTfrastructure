#!/usr/bin/env python3
"""Validate and launch a preserved ordinary compiler plan without changing its build command."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import re
import runpy
import subprocess
import sys
from functools import partial
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from proof_types import Json

from proof_commands import checked_run

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--plan", required=True, type=Path)
args = parser.parse_args()
plan = json.loads(args.plan.read_text())
assert plan['launcher_contract'] == 2
source = Path(plan["source"])
output = Path(plan["output"])
command = plan["command"]


run = partial(checked_run, timeout=30)


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def read_descriptor(context: Path, descriptor: Json) -> Path:
    algorithm, value = descriptor["digest"].split(":", 1)
    assert algorithm == "sha256" and re.fullmatch("[0-9a-f]{64}", value)
    path = context / "blobs" / algorithm / value
    assert path.stat().st_size == descriptor["size"] and digest(path) == value
    return path


assert command[:3] == ["systemd-run", "--user", "--no-block"]
assert f"--unit={plan['unit']}" in command
assert "--push" not in command and "--skip-preflight" not in command
assert command[command.index("--cross-targets") + 1] == "amd64,arm64,riscv64"
assert "TimeoutStartSec=21600" in command and "TimeoutStopSec=300" in command
assert "KillMode=control-group" in command and "RemainAfterExit=yes" in command
assert run(["git", "-C", str(source), "rev-parse", "HEAD"]).stdout.strip() == plan["source_revision"]
assert not run(["git", "-C", str(source), "status", "--porcelain"]).stdout.strip()
for path, head in [
    (Path.home() / "ANTfrastructure", "e08969b74f5e553e8262c7b51f73649fdbdfd41a"),
    (Path.home() / "gpu/work/hub-plugins", "e30b3e904eeb4f033b939a59086850c1f7dc8652"),
]:
    assert run(["git", "-C", str(path), "rev-parse", "HEAD"]).stdout.strip() == head
    assert not run(["git", "-C", str(path), "status", "--porcelain"]).stdout.strip()
registry = json.loads((source / 'docs/scripts/mutations.json').read_text())
assert len(registry) == plan['full_registry'] and len({row['id'] for row in registry}) == len(registry)
full = json.loads(Path(plan['full_source_preflight_proof']).read_text())
assert full['status'] == 'passed-complete-Linux-source-preflight-only'
assert full["source_revision"] == plan["source_revision"] and full["actual_full_registry_mutations"] == len(registry)
assert full["actual_preflight_group_count"] == 42 and full["command_exit_status"] == full["cleanup_exit_status"] == 0
assert full["owned_container_absent"] and full["unit_stopped_after_seal"] and full['independent_engine_query_exit_status'] == 0
assert full['script_suites'] > 0 and full['script_assertions'] > 0
targeted = json.loads(Path(plan['targeted_source_proof']).read_text())
assert targeted['status'] == 'passed-targeted-source-native-Clang-wrapper-and-backend-repair-only'
assert targeted['owner_source'] == str(source) and targeted['quality_group_count'] == 26
assert targeted['cleanup_exit_status'] == targeted['independent_engine_query_exit_status'] == 0 and targeted['owned_container_absent']
commit = json.loads(Path(plan['source_commit_proof']).read_text())
assert commit['head'] == plan['source_revision'] and commit['source'] == str(source)
assert commit['status'] == 'passed-local-source-commit-normal-hooks-only' and commit['normal_hook_status'] == 0
assert commit['actual_hook_mutations'] == 16 and commit['clean'] and commit['exact_committed_patch_match']
assert commit['patch_sha256'] == targeted['patch_sha256']
for filename, expected in plan['production_sha256'].items():
    assert digest(source / filename) == expected
audit = json.loads((args.plan.parent / plan["storage_path_audit"]).read_text())
for filename, expected in audit["files_sha256"].items():
    assert digest(source / filename) == expected
manager = dict(line.split("=", 1) for line in run(["systemctl", "--user", "show-environment"]).stdout.splitlines() if "=" in line)
assert all(key not in manager for key in audit["manager_keys_unset"])
assert run(["systemctl", "--user", "show", "--property=LoadState", "--value", plan["unit"]]).stdout.strip() == "not-found"
inventory = [json.loads(line) for line in run(["nerdctl", "images", "--digests", "--no-trunc", "--format", "{{json .}}"] ).stdout.splitlines() if line.strip()]
assert plan["local_image"] not in {f"{row['Repository']}:{row['Tag']}" for row in inventory}
assert not run(["nerdctl", "ps", "--format", "{{.ID}}"]).stdout.strip()
processes = run(["ps", "-eo", "pid,args"]).stdout.splitlines()
busy = [line for line in processes if re.search(r"(?:nerdctl|buildctl)\S*\s+build\b|build-cross-chain\.sh", line)]
assert not busy, busy
assert not output.exists()
temporary = Path(next(value.split("=", 1)[1] for value in command if value.startswith("TMPDIR=")))
assert not temporary.exists()
assert all(not (ancestor / ".git").exists() for ancestor in [temporary, *temporary.parents])
context = Path(next(value.split("=", 1)[1] for value in command if value.startswith("CROSS_COMPILER_BASE_CONTEXT=")))
assert digest(context / "index.json") == plan["base_oci_index_sha256"]
index = json.loads((context / "index.json").read_text())
assert len(index["manifests"]) == 1 and index["manifests"][0]["digest"] == plan["base_manifest"]
manifest = json.loads(read_descriptor(context, index["manifests"][0]).read_text())
assert manifest["config"]["digest"] == plan["base_config"] and len(manifest["layers"]) == 12
config = json.loads(read_descriptor(context, manifest["config"]).read_text())
assert config["architecture"] == "amd64" and config["os"] == "linux"
assert len(config["rootfs"]["diff_ids"]) == 12
for descriptor in manifest["layers"]:
    read_descriptor(context, descriptor)
base_reference = next(value.split("=", 1)[1] for value in command if value.startswith("CROSS_COMPILER_BASE_IMAGE="))
base_repository = base_reference.split("@", 1)[0]
base_candidates = [row for row in inventory if row["Repository"] == base_repository and row["Digest"] == plan["base_manifest"] and row["ID"] == plan["base_manifest"]]
assert len(base_candidates) == 1
base_alias = f"{base_candidates[0]['Repository']}:{base_candidates[0]['Tag']}"
base_image = json.loads(run(["nerdctl", "image", "inspect", base_alias]).stdout)[0]
assert base_image["Id"] == plan["base_config"]
assert any(value.endswith("@" + plan["base_manifest"]) for value in base_image["RepoDigests"])
sys.path.insert(0, str(source / "linux/scripts"))
disk = runpy.run_path(str(source / "linux/scripts/launch-migraphx-configure-proof.py"))["require_build_disk"](output.parent)
assert disk["available_bytes"] >= plan["required_bytes"]
output.mkdir()
temporary.mkdir(mode=0o700)
record = {
    **plan, "created_at": datetime.datetime.now(datetime.UTC).isoformat(), "status": "validated-ready-to-launch",
    "disk_admission": disk, "base_layers_rehashed": 12, "source_clean": True,
    "base_inspection_alias": base_alias, "base_alias_manifest_independently_matched": True,
    "preserved_main_and_E30": True, "manager_flags_revalidated": True,
    "full_source_preflight_verified": True, "full_registry_revalidated": len(registry),
    "full_source_preflight_sha256": digest(Path(plan['full_source_preflight_proof'])),
    "targeted_and_normal_hook_patch_binding_verified": True,
    "launcher": str(Path(__file__).resolve()), "launcher_sha256": digest(Path(__file__).resolve()),
    "actual_compiler_or_cache_pass_claimed": False, "publication": False,
}
invocation = output / "invocation.json"
invocation.write_text(json.dumps(record, indent=2) + chr(10))
result = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
record.update(status="launched" if result.returncode == 0 else "launch-failed", launch_status=result.returncode, stdout=result.stdout, stderr=result.stderr)
invocation.write_text(json.dumps(record, indent=2) + chr(10))
print(json.dumps({"unit": plan["unit"], "launch_status": result.returncode, "disk": disk, "base_layers_rehashed": 12, "stderr": result.stderr}))
raise SystemExit(result.returncode)
