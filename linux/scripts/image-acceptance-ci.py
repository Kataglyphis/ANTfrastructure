#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Run the complete frozen consumer contract on a matching native host (docs/image-acceptance.md#native-ci-proofs)."""

import argparse
import json
import os
import platform
import runpy
import shutil
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path
from types import SimpleNamespace
from typing import Any, TypedDict, cast

ROOT = Path(__file__).resolve().parents[2]


class FrozenSource(TypedDict):
    name: str
    repository: str
    revision: str
    submodules: str
    data_locks: dict[str, str]


class NativeProof(TypedDict):
    schema_version: int
    hub_revision: str
    image: str
    platform: str
    sources: list[FrozenSource]


def acceptance_api(hub: Path) -> dict[str, Any]:
    return runpy.run_path(str(hub / "linux/scripts/image-acceptance.py"))


def validate_source(source: FrozenSource, spec: dict[str, Any], api: dict[str, Any]) -> None:
    if not isinstance(source, dict) or set(source) != {"name", "repository", "revision", "submodules", "data_locks"}:
        raise ValueError("proof sources must preserve the complete source snapshot")
    if (source["name"], source["repository"]) != (spec["name"], spec["repository"]):
        raise ValueError("proof sources must match every consumer in plan order")
    if not isinstance(source["revision"], str) or not api["SHA"].fullmatch(source["revision"]):
        raise ValueError("proof consumer revision must be a full immutable commit")
    if not isinstance(source["submodules"], str) or not isinstance(source["data_locks"], dict):
        raise TypeError("proof submodules and data locks are required")


def read_proof(path: Path, api: dict[str, Any]) -> NativeProof:
    proof = cast(NativeProof, json.loads(path.read_text(encoding="utf-8")))
    if not isinstance(proof, dict) or set(proof) != {"schema_version", "hub_revision", "image", "platform", "sources"} or proof["schema_version"] != 1:
        raise ValueError("unsupported native image proof schema")
    api["image_parts"](proof["image"])
    if not isinstance(proof["hub_revision"], str) or not api["SHA"].fullmatch(proof["hub_revision"]):
        raise ValueError("proof hub revision must be a full immutable commit")
    if not api["supported_platform"](proof["platform"]):
        raise ValueError("unsupported native proof platform")
    plan = api["read_plan"](api["DEFAULT_PLAN"])
    if not isinstance(proof["sources"], list) or len(proof["sources"]) != len(plan["consumers"]):
        raise ValueError("proof must include the complete consumer source list")
    for source, spec in zip(proof["sources"], plan["consumers"]):
        validate_source(source, spec, api)
    return proof


def require_native(target: str) -> None:
    native = {"x86_64": "linux/amd64", "aarch64": "linux/arm64", "riscv64": "linux/riscv64"}.get(platform.machine().lower())
    if sys.platform != "linux" or native != target:
        raise ValueError("native consumer proof requires the runner architecture to match the complete plan")


def verify_hub(hub: Path, revision: str, api: dict[str, Any]) -> None:
    if api["git"](hub, "rev-parse", "HEAD") != revision or api["git"](hub, "status", "--porcelain"):
        raise ValueError("native proof requires the exact clean frozen hub")


def describe(args: argparse.Namespace) -> None:
    proof = read_proof(args.proof, acceptance_api(ROOT))
    require_native(proof["platform"])
    with args.github_output.open("a", encoding="utf-8") as stream:
        values = {"image": proof["image"], "hub_revision": proof["hub_revision"], "platform": proof["platform"]}
        for key, value in values.items():
            stream.write(f"{key}={value}\n")


def verify_result(receipt: dict[str, Any], proof: NativeProof, plan: Path, api: dict[str, Any]) -> None:
    api["validate_receipt"](receipt, proof["image"], plan)
    if receipt["hub_revision"] != proof["hub_revision"]:
        raise ValueError("receipt changed the frozen hub revision")
    actual = [(row["name"], row["revision"]) for row in receipt["consumers"]]
    expected = [(row["name"], row["revision"]) for row in proof["sources"]]
    if actual != expected:
        raise ValueError("receipt changed the frozen consumer revisions")


def engine_query(engine: str) -> dict[str, Any]:
    try:
        probe = subprocess.run([engine, "ps", "--all", "--format", "{{.Names}}"], capture_output=True, text=True, timeout=60, check=False)
        return {"exit_code": probe.returncode, "stdout": probe.stdout, "stderr": probe.stderr}
    except (OSError, subprocess.SubprocessError) as error:
        return {"exit_code": None, "stdout": "", "stderr": str(error)}


def save_metadata(output: Path, metadata: dict[str, Any], engine: str, api: dict[str, Any]) -> None:
    probe = engine_query(engine)
    metadata["engine_final"] = probe
    clean = probe["exit_code"] == 0 and not probe["stdout"].strip()
    metadata["status"] = "passed" if clean and metadata.get("consumer_check") == "passed" else "failed"
    metadata["finished_at"] = datetime.now(UTC).isoformat()
    metadata["disk_free_bytes_finished"] = shutil.disk_usage(output).free
    metadata["logs"] = [{"path": str(path), "artifact_path": path.relative_to(output).as_posix(), "sha256": api["fingerprint"](path)} for path in sorted((output / "consumers").glob("*.log"))]
    receipt = output / "receipt.json"
    if receipt.exists():
        metadata["receipt_sha256"] = api["fingerprint"](receipt)
    (output / "native-job.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    if not clean:
        raise ValueError("native acceptance did not finish with a successful empty engine query")


def run_native(args: argparse.Namespace) -> None:
    hub = args.hub.resolve()
    api = acceptance_api(hub)
    proof = read_proof(args.proof, api)
    require_native(proof["platform"])
    verify_hub(hub, proof["hub_revision"], api)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    plan = output / "plan.json"
    api["materialize_plan"](str(api["DEFAULT_PLAN"]), str(plan), proof["platform"])
    selected = api["read_plan"](plan)
    if selected != {**api["read_plan"](api["DEFAULT_PLAN"]), "platform": proof["platform"]}:
        raise ValueError("native acceptance must preserve every original command and timeout")
    metadata: dict[str, Any] = {"status": "failed", "started_at": datetime.now(UTC).isoformat(), "platform": proof["platform"], "host_architecture": platform.machine(), "image": proof["image"], "hub_revision": proof["hub_revision"], "proof_sha256": api["fingerprint"](args.proof), "plan_sha256": api["fingerprint"](plan), "source_snapshots": []}
    metadata["ci"] = {name: os.environ.get(name) for name in ("GITHUB_REPOSITORY", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_SHA", "GITHUB_REF")}
    metadata["host"] = {"architecture": platform.machine(), "system": sys.platform, "python": sys.version, "cpus": os.cpu_count(), "disk_free_bytes_started": shutil.disk_usage(output).free}
    try:
        for spec, source in zip(selected["consumers"], proof["sources"]):
            print("Preparing frozen consumer " + source["name"] + " at " + source["revision"], flush=True)
            snapshot = api["source_snapshot"](output / "consumers" / spec["name"], spec, source)
            metadata["source_snapshots"].append({"name": spec["name"], **snapshot})
        print("Running the complete unchanged consumer contract on " + proof["image"], flush=True)
        api["check"](SimpleNamespace(image=proof["image"], plan=str(plan), workspace=str(output / "consumers"), receipt=str(output / "receipt.json"), engine=args.engine, replay=None))
        receipt = json.loads((output / "receipt.json").read_text(encoding="utf-8"))
        verify_result(receipt, proof, plan, api)
        verify_hub(hub, proof["hub_revision"], api)
        metadata["consumer_check"] = "passed"
    finally:
        save_metadata(output, metadata, args.engine, api)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    info = commands.add_parser("describe")
    info.add_argument("--proof", type=Path, required=True)
    info.add_argument("--github-output", type=Path, required=True)
    run = commands.add_parser("run")
    run.add_argument("--proof", type=Path, required=True)
    run.add_argument("--hub", type=Path, required=True)
    run.add_argument("--output", type=Path, required=True)
    run.add_argument("--engine", default="docker")
    args = parser.parse_args()
    if args.action == "describe":
        describe(args)
    else:
        run_native(args)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, TypeError, OSError, subprocess.SubprocessError) as error:
        print(f"image-acceptance-ci: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        sys.exit(1)
