#!/usr/bin/env python3
"""Launch a normal per-arch SDK only from the qualified exact native compiler OCI; no publication or GPU acceptance."""

import argparse
import importlib.util
import json
from pathlib import Path

from normal_stage_launch import full_source, launch_stage
from proof_commands import checked_run

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--compiler-plan", required=True, type=Path)
parser.add_argument("--parent-proof", required=True, type=Path)
parser.add_argument("--arch", choices=["amd64", "arm64", "riscv64"], required=True)
parser.add_argument("--output", required=True, type=Path)
parser.add_argument("--unit", required=True)
parser.add_argument("--sdk-source", type=Path)
parser.add_argument("--sdk-source-proof", type=Path)
parser.add_argument("--image-repo")
args = parser.parse_args()
plan = json.loads(args.compiler_plan.read_text())
parent = json.loads(args.parent_proof.read_text())
producer_source = Path(plan["source"])
source = args.sdk_source.resolve() if args.sdk_source else producer_source
out = args.output.resolve()
engine = str(Path.home() / ".local/bin/nerdctl")


run = checked_run


assert args.unit.startswith(f"webgpu-normal-sdk-{args.arch}-") and args.unit.endswith(".service")
assert parent["status"] == "passed-qualified-native-compiler-OCI-and-base-ancestry"
assert parent["SDK_parent_prerequisites_passed"] and parent["matched_base_layers_and_diffIDs"] == 12
assert parent["source_revision"] == plan["source_revision"]
assert parent["stopped"]["ActiveState"] == "inactive" and parent["stopped"]["MainPID"] == "0"
assert run(["git", "-C", str(producer_source), "rev-parse", "HEAD"]).stdout.strip() == plan["source_revision"]
assert not run(["git", "-C", str(producer_source), "status", "--porcelain"]).stdout.strip()
assert not run(["git", "-C", str(source), "status", "--porcelain"]).stdout.strip()
producer_full = full_source(producer_source, args.compiler_plan.parent / "full-preflight-1/complete-preflight-proof.json", plan["source_revision"])
assert bool(args.sdk_source) == bool(args.sdk_source_proof)
source_revision = run(["git", "-C", str(source), "rev-parse", "HEAD"]).stdout.strip()
full = full_source(source, args.sdk_source_proof, source_revision) if args.sdk_source_proof else producer_full
assert full["all_default_preflight_groups"] == producer_full["all_default_preflight_groups"]
assert (source / "linux/scripts/01-core/versions.env").read_bytes() == (producer_source / "linux/scripts/01-core/versions.env").read_bytes()
if source_revision != plan["source_revision"]:
    changed = run(["git", "-C", str(source), "diff", "--name-only", plan["source_revision"], source_revision]).stdout.splitlines()
    production = [name for name in changed if name.startswith("linux/") and not name.startswith("linux/scripts/tests/")]
    assert production == ["linux/scripts/02-toolchain/materialize-llvm-target.sh"], "Review any other producer change before reusing this compiler"
    assert "test-llvm-target-aliases.sh" in full["executed_script_suites"]
    assert (source / "linux/Dockerfile.sdk").read_bytes() == (producer_source / "linux/Dockerfile.sdk").read_bytes()
    assert "COPY --chmod=755 linux/scripts/02-toolchain/materialize-llvm-target.sh /opt/scripts/toolchain/materialize-llvm-target.sh" in (source / "linux/Dockerfile.sdk").read_text()
repo = args.image_repo or plan["command"][plan["command"].index("--image-repo") + 1]
module_path = Path(__file__).with_name("native-oci-handoff.py")
spec = importlib.util.spec_from_file_location("native_oci_handoff", module_path)
assert spec is not None and spec.loader is not None, 'Native OCI helper has no importable module loader'
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
context = Path(parent["context"])
assert module.sha(context / "index.json") == parent["index_sha256"]
native = module.native_layout(context)
assert native[0] == parent["manifest"] and native[1]["config"]["digest"] == parent["config"]
qualification = module.qualification(Path(parent["qualification_proof"]), plan)
assert module.sha(Path(parent["qualification_proof"])) == parent["qualification_sha256"]
actual = json.loads(run([engine, "image", "inspect", plan["local_image"]]).stdout)[0]
assert actual["Id"] == parent["config"] and any(value.endswith("@" + parent["manifest"]) for value in actual["RepoDigests"])
record = {"source_revision": source_revision, "parent_source_revision": plan["source_revision"],
          "parent_OCI_proof": str(args.parent_proof.resolve()), "parent_manifest": parent["manifest"],
          "parent_config": parent["config"], "parent_OCI_index_sha256": parent["index_sha256"],
          "source_full_preflight_passed": True, "producer_source_unchanged": True,
          "SDK_source_full_preflight_proof": str(args.sdk_source_proof.resolve()) if args.sdk_source_proof else str(args.compiler_plan.parent / "full-preflight-1/complete-preflight-proof.json"),
          "parent_source_full_preflight_preserved": True, "scope": __doc__}
base_reference = plan["local_image"].rsplit(":", 1)[0] + "@" + parent["manifest"]
raise SystemExit(launch_stage(source, out, args.unit, repo, "sdk", args.arch, context, base_reference, plan["required_bytes"], record))
