#!/usr/bin/env python3
"""Export and verify the qualified compiler's exact native OCI/base ancestry; no SDK ABI or GPU proof."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import re
import runpy
import subprocess
import sys
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from proof_types import Json, NativeLayout

from proof_commands import checked_run

run = checked_run


def sha(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + chr(10))


def state(unit: str) -> dict[str, str]:
    raw = run(["systemctl", "--user", "show", unit, "--property=Id,LoadState,ActiveState,SubState,MainPID,Result,ExecMainStatus"]).stdout
    return dict(line.split("=", 1) for line in raw.splitlines())


def descriptor_path(context: Path, descriptor: Json) -> Path:
    algorithm, value = descriptor["digest"].split(":", 1)
    assert algorithm == "sha256" and re.fullmatch(r"[0-9a-f]{64}", value), "Invalid blob digest"
    path = context / "blobs" / algorithm / value
    assert path.is_file() and not path.is_symlink(), "Missing regular blob"
    assert path.stat().st_size == descriptor["size"] and sha(path) == value, "Blob bytes differ from descriptor"
    return path


def native_layout(context: Path) -> NativeLayout:
    assert json.loads((context / "oci-layout").read_text())["imageLayoutVersion"] == "1.0.0"
    index = json.loads((context / "index.json").read_text())
    assert index["schemaVersion"] == 2 and len(index["manifests"]) == 1, "Native OCI must select exactly one manifest"
    selected = index["manifests"][0]
    manifest = json.loads(descriptor_path(context, selected).read_text())
    assert manifest["schemaVersion"] == 2
    config = json.loads(descriptor_path(context, manifest["config"]).read_text())
    assert config["os"] == "linux" and config["architecture"] == "amd64", "Compiler must be native Linux amd64"
    assert config["rootfs"]["type"] == "layers" and len(config["rootfs"]["diff_ids"]) == len(manifest["layers"])
    for layer in manifest["layers"]:
        descriptor_path(context, layer)
    return selected["digest"], manifest, config


def base_ancestry(child: NativeLayout, parent: NativeLayout) -> int:
    _, manifest, config = child
    _, parent_manifest, parent_config = parent
    count = len(parent_manifest["layers"])
    assert count == 12 and len(manifest["layers"]) >= count
    assert manifest["layers"][:count] == parent_manifest["layers"], "Base layer ancestry differs"
    assert config["rootfs"]["diff_ids"][:count] == parent_config["rootfs"]["diff_ids"], "Base diffID ancestry differs"
    return count


def qualification(path: Path, plan: Json) -> Json:
    proof = json.loads(path.read_text())
    assert proof.get("status") == "passed-fresh-image-baked-compiler-native-tool-and-loader-selection-only", "Fresh complete compiler qualification required"
    assert proof["source_revision"] == plan["source_revision"]
    assert proof["owned_container_absent"] and proof["independent_engine_query_exit_status"] == proof["cleanup"]["exit_status"] == 0
    assert proof["container_environment_matches_baked_image"] and proof["baked_script_bytes_match_source"]
    assert proof["login_shell_selection_passed"]
    assert proof["native_facts"]["native_tool_count"] == 157
    if plan.get('launcher_contract') == 2:
        assert proof['cross_wrapper_checks_required'] and proof['cross_wrapper_CPU_checks_passed']
        assert set(proof['cross_wrapper_modes']) == {'default','login'}
        for mode,result in proof['cross_wrapper_modes'].items():
            assert result['status'] == 'passed-baked-cross-Clang-wrappers-and-CPU-smokes-only' and result['mode'] == mode
            assert result['native_backends'] == ['AArch64','RISCV','X86'] and result['wrapper_count'] == 6
            assert result['foreign_static_executions_required'] == 4 and result['native_languages'] == ['c','cxx']
    return proof


def launch(args: argparse.Namespace, plan: Json, proof: Json) -> int:
    assert state(args.unit)["LoadState"] == "not-found" and not args.context.exists()
    assert args.context.parent.is_dir()
    scripts = Path(plan["source"]) / "linux/scripts"
    sys.path.insert(0, str(scripts))
    disk = runpy.run_path(str(scripts / "launch-migraphx-configure-proof.py"))["require_build_disk"](args.context.parent)
    assert disk["available_bytes"] >= plan["required_bytes"]
    image = json.loads(run([str(Path.home() / ".local/bin/nerdctl"), "image", "inspect", plan["local_image"]]).stdout)[0]
    assert image["Id"] == proof["image_config"] and any(item.endswith("@" + proof["actual_image_manifest"]) for item in image["RepoDigests"])
    helper = Path(plan["source"]) / "linux/scripts/01-core/context-management.sh"
    engine = str(Path.home() / ".local/bin/nerdctl")
    command = ["systemd-run", "--user", "--no-block", "--expand-environment=no", f"--unit={args.unit}",
               "-p", "Type=oneshot", "-p", "RemainAfterExit=yes", "-p", "TimeoutStartSec=1200", "-p", "TimeoutStopSec=120",
               "-p", "KillMode=control-group", "-p", f"StandardOutput=append:{args.context}.unit.log", "-p", f"StandardError=append:{args.context}.unit.log",
               "-E", "LC_ALL=C", "-E", f"HOME={Path.home()}", "-E", f"PATH={Path.home()}/.local/bin:/usr/local/bin:/usr/bin:/bin",
               "/bin/bash", "-euo", "pipefail", "-c", 'source "$1"; declare -F export_image_to_oci_layout >/dev/null; export_image_to_oci_layout "$2" "$3" "$4"',
               "qualified-compiler-native-export", str(helper), engine, plan["local_image"], str(args.context)]
    invocation = args.context.with_suffix(".invocation.json")
    assert not invocation.exists()
    record = {"created_at": datetime.datetime.now(datetime.UTC).isoformat(), "unit": args.unit, "command": command,
              "context": str(args.context), "qualification_proof": str(args.qualification.resolve()), "qualification_sha256": sha(args.qualification),
              "source_revision": plan["source_revision"], "manifest": proof["actual_image_manifest"], "config": proof["image_config"],
              "disk_admission": disk, "scope": __doc__, "publication": False}
    save(invocation, record)
    result = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
    record.update(launch_status=result.returncode, stdout=result.stdout, stderr=result.stderr)
    save(invocation, record)
    print(json.dumps({"unit": args.unit, "launch_status": result.returncode, "context": str(args.context)}))
    return result.returncode


def seal(args: argparse.Namespace, plan: Json, proof: Json) -> int:
    invocation = json.loads(args.context.with_suffix(".invocation.json").read_text())
    assert invocation["unit"] == args.unit and invocation["qualification_sha256"] == sha(args.qualification)
    terminal = state(args.unit)
    assert terminal["LoadState"] == "loaded" and terminal["ActiveState"] == "active" and terminal["SubState"] == "exited"
    assert terminal["MainPID"] == terminal["ExecMainStatus"] == "0" and terminal["Result"] == "success"
    child = native_layout(args.context)
    assert child[0] == invocation["manifest"] == proof["actual_image_manifest"]
    assert child[1]["config"]["digest"] == invocation["config"] == proof["image_config"]
    base_context = Path(next(item.split("=", 1)[1] for item in plan["command"] if item.startswith("CROSS_COMPILER_BASE_CONTEXT=")))
    assert sha(base_context / "index.json") == plan["base_oci_index_sha256"]
    parent = native_layout(base_context)
    assert parent[0] == plan["base_manifest"] and parent[1]["config"]["digest"] == plan["base_config"]
    ancestors = base_ancestry(child, parent)
    record = {"status": "passed-qualified-native-compiler-OCI-and-base-ancestry", "observed_at": datetime.datetime.now(datetime.UTC).isoformat(),
              "source_revision": plan["source_revision"], "terminal_before_stop": terminal, "context": str(args.context),
              "manifest": child[0], "config": child[1]["config"]["digest"], "layers": len(child[1]["layers"]),
              "all_native_blob_sizes_and_sha256_verified": True, "matched_base_layers_and_diffIDs": ancestors,
              "index_sha256": sha(args.context / "index.json"), "qualification_proof": str(args.qualification.resolve()),
              "qualification_sha256": sha(args.qualification), "SDK_parent_prerequisites_passed": True,
              "SDK_built": False, "GPU_or_final_image_acceptance": False, "scope": __doc__, "publication": False}
    output = args.context.with_suffix(".proof.json")
    assert not output.exists()
    save(output, record)
    run(["systemctl", "--user", "stop", args.unit])
    record["stopped"] = state(args.unit)
    assert record["stopped"]["ActiveState"] == "inactive" and record["stopped"]["MainPID"] == "0"
    save(args.context.with_suffix(".proof-stopped.json"), record)
    print(json.dumps({"status": record["status"], "manifest": child[0], "base_layers_and_diffIDs": ancestors}))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["launch", "seal"])
    parser.add_argument("--plan", required=True, type=Path)
    parser.add_argument("--qualification", required=True, type=Path)
    parser.add_argument("--context", required=True, type=Path)
    parser.add_argument("--unit", required=True)
    args = parser.parse_args()
    plan = json.loads(args.plan.read_text())
    args.context = args.context.resolve()
    assert re.fullmatch(r"webgpu-normal-compiler-export-[0-9-]+\.service", args.unit)
    assert args.context.parent == args.plan.resolve().parent and args.context.name.startswith("compiler-context-")
    assert run(["git", "-C", plan["source"], "rev-parse", "HEAD"]).stdout.strip() == plan["source_revision"]
    assert not run(["git", "-C", plan["source"], "status", "--porcelain"]).stdout.strip()
    proof = qualification(args.qualification, plan)
    return launch(args, plan, proof) if args.action == "launch" else seal(args, plan, proof)


if __name__ == "__main__":
    raise SystemExit(main())
