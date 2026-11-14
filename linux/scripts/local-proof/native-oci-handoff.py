#!/usr/bin/env python3
"""Export and verify reviewed compiler/amd64-SDK native OCI ancestry; no foreign SDK, complete C++ ABI or GPU proof."""

from __future__ import annotations

import argparse
import datetime
import json
import re
import runpy
import subprocess
import sys
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from proof_types import Json

from native_oci_layout import (
    base_ancestry,
    descriptor_path,
    layer_ancestry,
    native_layout,
    sha,
)
from native_oci_seed import verify_seed
from proof_commands import checked_run
from proof_subject import load_subject, validate_subject_binding

__all__ = [
    'base_ancestry', 'descriptor_path', 'export_worker_inputs', 'launch', 'layer_ancestry', 'main',
    'native_layout', 'qualification', 'save', 'sdk_cpu_qualification', 'seal', 'sha', 'state',
]

run = checked_run


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + chr(10))


def state(unit: str) -> dict[str, str]:
    raw = run(["systemctl", "--user", "show", unit, "--property=Id,LoadState,ActiveState,SubState,MainPID,Result,ExecMainStatus"]).stdout
    return dict(line.split("=", 1) for line in raw.splitlines())


def sdk_cpu_qualification(proof: Json, subject: Json) -> None:
    validate_subject_binding(proof, subject, cpu_checks=True)
    assert proof['sdk_native_checks_required'] and proof['sdk_native_CPU_checks_passed'], 'SDK native CPU checks are required'
    assert not proof['cross_wrapper_checks_required'] and set(proof['sdk_native_modes']) == {'default','login'}, 'SDK proof requires both native modes'
    for mode, result in proof['sdk_native_modes'].items():
        assert result['status'] == 'passed-baked-SDK-Clang-wrappers-and-CPU-smokes-only' and result['profile'] == 'sdk-amd64' and result['mode'] == mode, 'SDK native mode identity differs'
        assert result['native_backends'] == ['AArch64','AMDGPU','RISCV','X86'] and result['wrapper_count'] == 2 and result['cross_targets'] == ['amd64'], 'SDK native compiler scope differs'
        assert result['native_languages'] == ['c','cxx'] and result['foreign_static_executions_required'] == 0, 'SDK native languages differ'


def qualification(path: Path, plan: Json, sdk_invocation: Path | None = None) -> Json:
    subject = load_subject(plan, sdk_invocation)
    proof = json.loads(path.read_text())
    assert proof.get("status") == subject['qualification_status'], "Fresh complete compiler qualification required"
    assert proof["source_revision"] == plan["source_revision"]
    assert proof["owned_container_absent"] and proof["independent_engine_query_exit_status"] == proof["cleanup"]["exit_status"] == 0
    assert proof["container_environment_matches_baked_image"] and proof["baked_script_bytes_match_source"]
    assert proof["login_shell_selection_passed"]
    assert proof["native_facts"]["native_tool_count"] == 157
    if subject['kind'] == 'sdk-amd64':
        sdk_cpu_qualification(proof, subject)
    elif plan.get('launcher_contract') == 2:
        assert proof['cross_wrapper_checks_required'] and proof['cross_wrapper_CPU_checks_passed']
        assert set(proof['cross_wrapper_modes']) == {'default','login'}
        for mode,result in proof['cross_wrapper_modes'].items():
            assert result['status'] == 'passed-baked-cross-Clang-wrappers-and-CPU-smokes-only' and result['mode'] == mode
            assert result['native_backends'] == ['AArch64','AMDGPU','RISCV','X86'] and result['wrapper_count'] == 6
            assert result['foreign_static_executions_required'] == 4 and result['native_languages'] == ['c','cxx']
    return proof


def export_worker_inputs(plan: Json, sdk: bool) -> dict[str, str]:
    helper = Path(__file__).resolve().parents[1] / '01-core/context-management.sh' if sdk else Path(plan['source']) / 'linux/scripts/01-core/context-management.sh'
    paths = [helper,Path(__file__).with_name('native_oci_seed.py'),Path(__file__).with_name('native_oci_layout.py')] if sdk else [helper]
    return {str(path):sha(path) for path in paths}


def launch(args: argparse.Namespace, plan: Json, proof: Json) -> int:
    subject = load_subject(plan, args.sdk_invocation)
    assert state(args.unit)["LoadState"] == "not-found" and not args.context.exists()
    assert args.context.parent.is_dir()
    scripts = Path(plan["source"]) / "linux/scripts"
    sys.path.insert(0, str(scripts))
    disk = runpy.run_path(str(scripts / "launch-migraphx-configure-proof.py"))["require_build_disk"](args.context.parent)
    assert disk["available_bytes"] >= plan["required_bytes"]
    image = json.loads(run([str(Path.home() / ".local/bin/nerdctl"), "image", "inspect", subject['image']]).stdout)[0]
    assert image["Id"] == proof["image_config"] and any(item.endswith("@" + proof["actual_image_manifest"]) for item in image["RepoDigests"])
    sdk = subject['kind'] == 'sdk-amd64'
    worker_inputs = export_worker_inputs(plan,sdk)
    helper = Path(next(iter(worker_inputs)))
    parent_proof = subject['compiler_parent_proof'] if sdk else ''
    engine = str(Path.home() / ".local/bin/nerdctl")
    command = ["systemd-run", "--user", "--no-block", "--expand-environment=no", f"--unit={args.unit}",
               "-p", "Type=oneshot", "-p", "RemainAfterExit=yes", "-p", "TimeoutStartSec=1200", "-p", "TimeoutStopSec=120",
               "-p", "KillMode=control-group", "-p", f"StandardOutput=append:{args.context}.unit.log", "-p", f"StandardError=append:{args.context}.unit.log",
               "-E", "LC_ALL=C", "-E", f"HOME={Path.home()}", "-E", f"PATH={Path.home()}/.local/bin:/usr/local/bin:/usr/bin:/bin",
               "/bin/bash", "-euo", "pipefail", "-c", 'source "$1"; declare -F export_image_to_oci_layout >/dev/null; export_image_to_oci_layout "$2" "$3" "$4" "${5:-}"',
               "qualified-native-export", str(helper), engine, subject['image'], str(args.context), parent_proof]
    invocation = args.context.with_suffix(".invocation.json")
    assert not invocation.exists()
    record = {"created_at": datetime.datetime.now(datetime.UTC).isoformat(), "unit": args.unit, "command": command,
              "context": str(args.context), 'subject':subject, "qualification_proof": str(args.qualification.resolve()), "qualification_sha256": sha(args.qualification),
              "source_revision": plan["source_revision"], "manifest": proof["actual_image_manifest"], "config": proof["image_config"],
              "disk_admission": disk, 'parent_layer_reuse_required':sdk,
              'export_input_sha256':worker_inputs,
              "scope": __doc__, "publication": False}
    save(invocation, record)
    result = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
    record.update(launch_status=result.returncode, stdout=result.stdout, stderr=result.stderr)
    save(invocation, record)
    print(json.dumps({"unit": args.unit, "launch_status": result.returncode, "context": str(args.context)}))
    return result.returncode


def seal(args: argparse.Namespace, plan: Json, proof: Json) -> int:
    subject = load_subject(plan, args.sdk_invocation)
    sdk = subject['kind'] == 'sdk-amd64'
    invocation = json.loads(args.context.with_suffix(".invocation.json").read_text())
    assert invocation["unit"] == args.unit and invocation["qualification_sha256"] == sha(args.qualification)
    validate_subject_binding(invocation, subject)
    assert invocation.get('parent_layer_reuse_required',False) == sdk, 'OCI parent reuse requirement differs'
    worker_inputs = export_worker_inputs(plan,sdk)
    assert invocation.get('export_input_sha256',worker_inputs if not sdk else {}) == worker_inputs, 'OCI export worker bytes changed'
    terminal = state(args.unit)
    assert terminal["LoadState"] == "loaded" and terminal["ActiveState"] == "active" and terminal["SubState"] == "exited"
    assert terminal["MainPID"] == terminal["ExecMainStatus"] == "0" and terminal["Result"] == "success"
    child = native_layout(args.context)
    assert child[0] == invocation["manifest"] == proof["actual_image_manifest"]
    assert child[1]["config"]["digest"] == invocation["config"] == proof["image_config"]
    if sdk:
        original = json.loads(Path(subject['compiler_parent_proof']).read_text())
        base_context = Path(original['context'])
        expected_index, expected_manifest, expected_config = original['index_sha256'], original['manifest'], original['config']
        expected_count = original['layers']
        parent, reuse = verify_seed(Path(subject['compiler_parent_proof']), args.context)
        transport = json.loads(Path(str(args.context) + '.transport.json').read_text())
        assert transport == {'producer_status':0,'extractor_status':0}, 'OCI producer or extractor failed'
    else:
        base_context = Path(next(item.split("=", 1)[1] for item in plan["command"] if item.startswith("CROSS_COMPILER_BASE_CONTEXT=")))
        expected_index, expected_manifest, expected_config = plan['base_oci_index_sha256'], plan['base_manifest'], plan['base_config']
        expected_count = 12
        parent = native_layout(base_context)
    assert sha(base_context / 'index.json') == expected_index
    assert parent[0] == expected_manifest and parent[1]['config']['digest'] == expected_config
    ancestors = layer_ancestry(child, parent, expected_count)
    status = 'passed-qualified-native-SDK-OCI-and-compiler-ancestry' if sdk else 'passed-qualified-native-compiler-OCI-and-base-ancestry'
    record = {"status": status, 'subject':subject, "observed_at": datetime.datetime.now(datetime.UTC).isoformat(),
              "source_revision": plan["source_revision"], "terminal_before_stop": terminal, "context": str(args.context),
              "manifest": child[0], "config": child[1]["config"]["digest"], "layers": len(child[1]["layers"]),
              "all_native_blob_sizes_and_sha256_verified": True,
              ('matched_compiler_layers_and_diffIDs' if sdk else 'matched_base_layers_and_diffIDs'): ancestors,
              "index_sha256": sha(args.context / "index.json"), "qualification_proof": str(args.qualification.resolve()),
              "qualification_sha256": sha(args.qualification), "SDK_parent_prerequisites_passed": not sdk,
              "SDK_built": sdk, "GPU_or_final_image_acceptance": False, "scope": __doc__, "publication": False}
    if sdk:
        record.update(parent_layer_reuse=reuse, export_transport=transport, parent_layer_reuse_verified=True)
    output = args.context.with_suffix(".proof.json")
    assert not output.exists()
    save(output, record)
    run(["systemctl", "--user", "stop", args.unit])
    record["stopped"] = state(args.unit)
    assert record["stopped"]["ActiveState"] == "inactive" and record["stopped"]["MainPID"] == "0"
    save(args.context.with_suffix(".proof-stopped.json"), record)
    print(json.dumps({"status": record["status"], "manifest": child[0], "parent_layers_and_diffIDs": ancestors}))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["launch", "seal"])
    parser.add_argument("--plan", required=True, type=Path)
    parser.add_argument("--qualification", required=True, type=Path)
    parser.add_argument("--context", required=True, type=Path)
    parser.add_argument("--unit", required=True)
    parser.add_argument('--sdk-invocation', type=Path)
    args = parser.parse_args()
    plan = json.loads(args.plan.read_text())
    args.context = args.context.resolve()
    sdk = args.sdk_invocation is not None
    unit_pattern = r'webgpu-normal-sdk-export-amd64-[0-9-]+\.service' if sdk else r'webgpu-normal-compiler-export-[0-9-]+\.service'
    assert re.fullmatch(unit_pattern, args.unit)
    assert args.context.parent == args.plan.resolve().parent and args.context.name.startswith('sdk-context-' if sdk else 'compiler-context-')
    assert run(["git", "-C", plan["source"], "rev-parse", "HEAD"]).stdout.strip() == plan["source_revision"]
    assert not run(["git", "-C", plan["source"], "status", "--porcelain"]).stdout.strip()
    proof = qualification(args.qualification, plan, args.sdk_invocation)
    return launch(args, plan, proof) if args.action == "launch" else seal(args, plan, proof)


if __name__ == "__main__":
    raise SystemExit(main())
