#!/usr/bin/env python3
"""Launch a normal per-arch SDK only from the qualified exact native compiler OCI; no publication or GPU acceptance."""

import argparse
import datetime
import importlib.util
import json
import runpy
import subprocess
import sys
from pathlib import Path

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
producer_full = json.loads((args.compiler_plan.parent / "full-preflight-1/complete-preflight-proof.json").read_text())
assert producer_full["source_revision"] == plan["source_revision"]
assert producer_full["status"] == "passed-complete-Linux-source-preflight-only"
assert producer_full["actual_full_registry_mutations"] == len(json.loads((producer_source / "docs/scripts/mutations.json").read_text()))
assert producer_full["command_exit_status"] == producer_full["cleanup_exit_status"] == producer_full["independent_engine_query_exit_status"] == 0
assert bool(args.sdk_source) == bool(args.sdk_source_proof)
source_revision = run(["git", "-C", str(source), "rev-parse", "HEAD"]).stdout.strip()
full = json.loads(args.sdk_source_proof.read_text()) if args.sdk_source_proof else producer_full
assert full["status"] == "passed-complete-Linux-source-preflight-only" and full["source_revision"] == source_revision
assert full["actual_full_registry_mutations"] == len(json.loads((source / "docs/scripts/mutations.json").read_text()))
assert full["command_exit_status"] == full["cleanup_exit_status"] == full["independent_engine_query_exit_status"] == 0
assert full["unit_stopped_after_seal"] and full["owned_container_absent"]
assert full["all_default_preflight_groups"] == producer_full["all_default_preflight_groups"]
assert (source / "linux/scripts/01-core/versions.env").read_bytes() == (producer_source / "linux/scripts/01-core/versions.env").read_bytes()
if source_revision != plan["source_revision"]:
    changed = run(["git", "-C", str(source), "diff", "--name-only", plan["source_revision"], source_revision]).stdout.splitlines()
    production = [name for name in changed if name.startswith("linux/") and not name.startswith("linux/scripts/tests/")]
    assert production == ["linux/scripts/02-toolchain/materialize-llvm-target.sh"], "Review any other producer change before reusing this compiler"
    assert "test-llvm-target-aliases.sh" in full["executed_script_suites"]
    assert (source / "linux/Dockerfile.sdk").read_bytes() == (producer_source / "linux/Dockerfile.sdk").read_bytes()
    assert "COPY --chmod=755 linux/scripts/02-toolchain/materialize-llvm-target.sh /opt/scripts/toolchain/materialize-llvm-target.sh" in (source / "linux/Dockerfile.sdk").read_text()
manager = dict(line.split("=", 1) for line in run(["systemctl", "--user", "show-environment"]).stdout.splitlines() if "=" in line)
assert not {key: value for key, value in manager.items() if key.startswith("CROSS_") or key in ("ENABLE_AMD", "ENABLE_NVIDIA", "ENABLE_DEEPSTREAM", "DRY_RUN")}
assert run(["systemctl", "--user", "show", args.unit, "--property=LoadState", "--value"]).stdout.strip() == "not-found"
assert not out.exists()
temporary = Path.home() / ".cache" / args.unit.removesuffix(".service")
assert not temporary.exists() and all(not (path / ".git").exists() for path in [temporary, *temporary.parents])
repo = args.image_repo or plan["command"][plan["command"].index("--image-repo") + 1]
assert repo.startswith("ant-local/webgpu-") and ":" not in repo and "@" not in repo
image = f"{repo}:cross-sdk-{args.arch}"
inventory = [json.loads(line) for line in run([engine, "images", "--format", "{{json .}}"] ).stdout.splitlines() if line.strip()]
assert image not in {f"{row['Repository']}:{row['Tag']}" for row in inventory}
assert not run([engine, "ps", "--format", "{{.ID}}"]).stdout.strip()
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
sys.path.insert(0, str(source / "linux/scripts"))
disk = runpy.run_path(str(source / "linux/scripts/launch-migraphx-configure-proof.py"))["require_build_disk"](out.parent)
assert disk["available_bytes"] >= plan["required_bytes"]
out.mkdir()
temporary.mkdir(mode=0o700)
base_reference = plan["local_image"].rsplit(":", 1)[0] + "@" + parent["manifest"]
command = ["systemd-run", "--user", "--no-block", "--expand-environment=no", f"--unit={args.unit}",
           "-p", "Type=oneshot", "-p", "RemainAfterExit=yes", "-p", "TimeoutStartSec=21600", "-p", "TimeoutStopSec=300",
           "-p", "KillMode=control-group", "-p", f"WorkingDirectory={source}",
           "-p", f"StandardOutput=append:{out}/unit.log", "-p", f"StandardError=append:{out}/unit.log",
           "-E", "LC_ALL=C", "-E", f"HOME={Path.home()}", "-E", f"PATH={Path.home()}/.local/bin:/usr/local/bin:/usr/bin:/bin",
           "-E", f"NERDCTL_BIN={engine}", "-E", "BUILDKIT_PROGRESS=plain", "-E", f"BUILDKIT_CACHE_DIR={out}/buildcache",
           "-E", f"CROSS_SDK_BASE_IMAGE={base_reference}", "-E", f"CROSS_SDK_BASE_CONTEXT={context}", "-E", f"TMPDIR={temporary}",
           "/bin/bash", str(source / "linux/scripts/build-cross-stage.sh"), "--stage", "sdk", "--arch", args.arch,
           "--image-repo", repo, "--log-dir", str(out / "logs")]
record = {"created_at": datetime.datetime.now(datetime.UTC).isoformat(), "unit": args.unit, "source": str(source),
          "source_revision": source_revision, "parent_source_revision": plan["source_revision"], "target_arch": args.arch, "image": image, "command": command,
          "parent_OCI_proof": str(args.parent_proof.resolve()), "parent_manifest": parent["manifest"],
          "parent_config": parent["config"], "parent_OCI_index_sha256": parent["index_sha256"],
          "disk_admission": disk, "source_full_preflight_passed": True, "producer_source_unchanged": True,
          "SDK_source_full_preflight_proof": str(args.sdk_source_proof.resolve()) if args.sdk_source_proof else str(args.compiler_plan.parent / "full-preflight-1/complete-preflight-proof.json"),
          "parent_source_full_preflight_preserved": True,
          "scope": __doc__, "outlives_turn": True, "publication": False}
path = out / "invocation.json"
path.write_text(json.dumps(record, indent=2) + chr(10))
result = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
record.update(launch_status=result.returncode, stdout=result.stdout, stderr=result.stderr)
path.write_text(json.dumps(record, indent=2) + chr(10))
print(json.dumps({"unit": args.unit, "launch_status": result.returncode, "parent_manifest": parent["manifest"], "disk": disk}))
raise SystemExit(result.returncode)
