#!/usr/bin/env python3
"""Qualify reviewed compiler and SDK tools, loader and CPU wrappers; no complete C++ ABI or GPU acceptance."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import runpy
import shutil
import subprocess
import uuid
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from proof_types import Json

from proof_commands import checked_run
from proof_subject import (
    load_subject,
    validate_foreign_sdk_image,
    validate_subject_binding,
)

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("action", choices=["launch", "seal"])
parser.add_argument("--plan", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--unit", required=True)
parser.add_argument("--plain-load-probe", type=Path, required=True)
parser.add_argument("--original-qualification", type=Path, required=True)
parser.add_argument('--sdk-invocation', type=Path)
args = parser.parse_args()
plan = json.loads(args.plan.read_text())
subject = load_subject(plan, args.sdk_invocation)
sdk_required = args.sdk_invocation is not None
source = Path(plan["source"])
out = args.output.resolve()
tools_dir = Path(__file__).resolve().parent
engine = str(Path.home() / ".local/bin/nerdctl")
owner_label = 'org.kataglyphis.sdk-image-qualification' if sdk_required else 'org.kataglyphis.compiler-image-qualification'
cross_required = subject['cross_required']
cpu_required = cross_required or sdk_required


run = checked_run


def state(unit: str) -> dict[str, str]:
    raw = run(["systemctl", "--user", "show", unit, "--property=Id,LoadState,ActiveState,SubState,MainPID,Result,ExecMainStatus"]).stdout
    return dict(line.split("=", 1) for line in raw.splitlines())


def successful(unit: str) -> dict[str, str]:
    value = state(unit)
    assert value["LoadState"] == "loaded" and value["ActiveState"] == "active" and value["SubState"] == "exited"
    assert value["MainPID"] == value["ExecMainStatus"] == "0" and value["Result"] == "success"
    return value


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + chr(10))


def checked_inventory() -> list[Json]:
    query = subprocess.run([engine, 'ps', '-a', '--format', '{{json .}}'], capture_output=True, text=True, timeout=60, check=False)
    save(out / "independent-engine-query.json", {"returncode": query.returncode, "stdout": query.stdout, "stderr": query.stderr})
    assert query.returncode == 0
    return [json.loads(line) for line in query.stdout.splitlines() if line.strip()]


assert args.unit.startswith(subject['unit_prefix']) and args.unit.endswith(".service")
assert run(["git", "-C", str(source), "rev-parse", "HEAD"]).stdout.strip() == plan["source_revision"]
assert not run(["git", "-C", str(source), "status", "--porcelain"]).stdout.strip()
if args.action == "launch":
    producer = successful(subject['producer_unit'])
    assert state(args.unit)["LoadState"] == "not-found" and not out.exists()
    cleanup = source / "linux/scripts/cleanup-owned-containers.py"
    run(["python3", str(cleanup), "--help"])
    image = json.loads(run([engine, "image", "inspect", subject['image']]).stdout)[0]
    if sdk_required and subject['kind'] != 'sdk-amd64':
        validate_foreign_sdk_image(image, subject)
    manifests = {value.rsplit("@", 1)[1] for value in image["RepoDigests"]}
    assert len(manifests) == 1
    manifest = manifests.pop()
    assert not image["Config"].get("Entrypoint")
    out.mkdir()
    (out / "results").mkdir()
    shutil.copyfile(tools_dir / "qualify-compiler-image.sh", out / "qualify.sh")
    if cross_required:
        assert args.plain_load_probe is not None, 'Pass the original retained bare-loader probe explicitly'
    previous = args.plain_load_probe.resolve() if args.plain_load_probe else args.plan.parent / "actual-replay-3/plain-load.py"
    original = args.original_qualification.resolve(strict=True)
    original_invocation = json.loads((original / 'invocation.json').read_text())
    assert sha(previous) == original_invocation['input_sha256']['plain-load.py'], 'Loader probe differs from the qualified original'
    shutil.copyfile(previous, out / "plain-load.py")
    inputs = ['qualify.sh', 'plain-load.py']
    if cpu_required:
        for name, target in [('qualify-compiler-with-cross.sh','qualify-with-cross.sh'), ('probe-cross-clang-image.py','cross-probe.py')]:
            shutil.copyfile(tools_dir / name, out / target)
            inputs.append(target)
        (out / 'inputs').mkdir()
        for name in ['native-wrapper-probe.c', 'native-wrapper-probe.cc']:
            shutil.copyfile(tools_dir / name, out / 'inputs' / name)
            inputs.append('inputs/' + name)
    token = uuid.uuid4().hex
    container = "ant-" + args.unit.removesuffix(".service")
    stop = f"ExecStopPost=/usr/bin/python3 {cleanup} --engine {engine} --owner-label {owner_label} --run-id {token} --cidfile {out}/container.cid --output {out}/retained-stop-cleanup.json --retain"
    command = ["systemd-run", "--user", "--no-block", "--expand-environment=no", f"--unit={args.unit}",
               "-p", "Type=oneshot", "-p", "RemainAfterExit=yes", "-p", "TimeoutStartSec=600", "-p", "TimeoutStopSec=120",
               "-p", "KillMode=control-group", "-p", f"StandardOutput=append:{out}/stdout.log",
               "-p", f"StandardError=append:{out}/stderr.log", "-p", stop,
               "-E", "LC_ALL=C", "-E", f"HOME={Path.home()}", "-E", f"PATH={Path.home()}/.local/bin:/usr/local/bin:/usr/bin:/bin",
               engine, "run", "--name", container, "--cidfile", str(out / "container.cid"), "--label", f"{owner_label}={token}",
               "--pull", "never", "--init", "--security-opt", "apparmor=unconfined", "--network", "none",
               "--cpus", "2", "--memory", "2g", "--user", "0:0", "--env", "LC_ALL=C",
               "-v", f"{out}/results:/evidence:rw", "-v", f"{out}/qualify.sh:/qualify.sh:ro",
               "-v", f"{out}/plain-load.py:/plain-load.py:ro", subject['image'], "bash", "/qualify.sh",
               plan["expected_pins"]["GCC_VERSION"], plan["expected_pins"]["LLVM_RELEASE"], subject['native_prefix']]
    assert command.count("--env") == 1 and "--entrypoint" not in command
    if cpu_required:
        offset = command.index(subject['image'])
        command[offset:offset] = ['-v', f'{out}/qualify-with-cross.sh:/qualify-with-cross.sh:ro',
                                 '-v', f'{out}/cross-probe.py:/cross-probe.py:ro', '-v', f'{out}/inputs:/inputs:ro']
        command[command.index('/qualify.sh')] = '/qualify-with-cross.sh'
        if sdk_required:
            command.append(subject['cpu_profile'])
    record = {"created_at": datetime.datetime.now(datetime.UTC).isoformat(), "unit": args.unit, "producer_unit": subject['producer_unit'], 'subject':subject,
              "producer_terminal": producer, "source_revision": plan["source_revision"], "source": str(source),
              "image": subject['image'], "expected_manifest": manifest, "expected_config": image["Id"],
              "image_config_environment": image["Config"]["Env"], "owner_label": owner_label, "run_id": token,
              "container": container, "command": command, "scope": __doc__, "publication": False,
              "input_sha256": {name: sha(out / name) for name in inputs},
              'cross_wrapper_checks_required':cross_required, 'sdk_native_checks_required':sdk_required, 'original_plain_loader_probe_sha256':sha(previous),
              'expected_cross_baked_sha256':{name:sha(source / 'linux/scripts/06-packaging' / name)
                                              for name in ['smoke-toolchain.sh','smoke-common.sh','probe-compiler-defaults.py','llvm-loader-path.sh']} if cpu_required else {},
              "expected_baked_sha256": {name: sha(source / "linux/scripts/06-packaging" / name) for name in ("probe-compiler-defaults.py", "llvm-loader-path.sh")}}
    save(out / "image-inspect.json", image)
    save(out / "invocation.json", record)
    launched = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
    record.update(launch_status=launched.returncode, stdout=launched.stdout, stderr=launched.stderr)
    save(out / "invocation.json", record)
    print(json.dumps({"unit": args.unit, "launch_status": launched.returncode, "expected_manifest": manifest}))
    raise SystemExit(launched.returncode)

inv = json.loads((out / "invocation.json").read_text())
assert inv["unit"] == args.unit and inv["source_revision"] == plan["source_revision"] and inv["owner_label"] == owner_label
validate_subject_binding(inv, subject, cpu_checks=True)
assert all(sha(out / name) == expected for name, expected in inv['input_sha256'].items())
terminal = successful(args.unit)
cid = (out / "container.cid").read_text().strip()
container = json.loads(run([engine, "inspect", cid]).stdout)[0]
save(out / "container-inspect.json", container)
assert container["Id"] == cid and container["Image"] == inv["expected_manifest"]
assert container["Config"]["Labels"][owner_label] == inv["run_id"]
assert not container["State"]["Running"] and container["State"]["ExitCode"] == 0
assert not container["HostConfig"].get("Privileged", False)
results = out / "results"
modes = {}
for prefix in ("", "login-"):
    native = json.loads((results / f"{prefix}native.json").read_text())
    defaults = json.loads((results / f"{prefix}defaults.json").read_text())
    loaded = json.loads((results / f"{prefix}loaded.json").read_text())
    assert native["status"] == "passed-native-llvm-tool-and-loader-selection-only"
    assert native["schema_version"] == 2
    assert native["facts"] == {"native_prefix": subject['native_prefix'], "native_tool_count": 157,
                               "llvm_config_version": "23.1.5", "native_library_sonames": ["libLLVM.so.23.1"]}
    assert all(row["dynamic"]["returncode"] == 0 and row["soname"] == "libLLVM.so.23.1" and row["cache_winner"] == row["source"] for row in native["libraries"])
    assert defaults["status"] == "passed-installed-amd64-compiler-defaults-only"
    assert set(defaults["facts"]) == {"gcc", "g++", "cc", "c++", "clang", "clang++"}
    for name in ("gcc", "g++", "cc", "c++"):
        facts = defaults["facts"][name]
        assert facts["version"] == "16.2.0" and facts["march"] == "x86-64-v3" and facts["mtune"] == "generic"
        assert facts["v3_defines"] == ["AVX2", "FMA", "BMI2"]
    assert all(defaults["facts"][name]["version"] == "23.1.5" for name in ("clang", "clang++"))
    assert loaded["status"] == "passed-bare-soname-mapping-only" and len(loaded["loaded"]) == 1
    assert loaded["loaded"][0]["path"].startswith(subject['native_prefix'] + '/lib/')
    source_sha, source_path = (results / f"{prefix}source-library-sha256.txt").read_text().split(maxsplit=1)
    assert source_path.strip() == native["libraries"][0]["source"]
    assert loaded["loaded"][0]["path"] == source_path.strip() and loaded["loaded"][0]["sha256"] == source_sha
    assert (results / f"{prefix}native-conf.txt").read_bytes() == b"/opt/llvm-target-amd64/lib\n"
    environment = json.loads((results / f"{prefix}environment.json").read_text())
    baked_environment = dict(value.split("=", 1) for value in inv["image_config_environment"])
    if not prefix:
        for key, value in environment.items():
            assert value == baked_environment.get(key), f"Unexpected container override: {key}"
    assert not environment["LD_PRELOAD"]
    baked = {Path(line.split()[1]).name: line.split()[0] for line in (results / f"{prefix}baked-script-sha256.txt").read_text().splitlines()}
    assert baked == inv["expected_baked_sha256"]
    modes[prefix or "default"] = {"native": native, "defaults": defaults, "loaded": loaded, "environment": environment}
native, defaults, loaded = [modes["default"][name] for name in ("native", "defaults", "loaded")]
assert all(sha(out / name) == expected for name, expected in inv["input_sha256"].items())
cross_modes = {}
if cpu_required:
    validate_cross = runpy.run_path(str(out / 'cross-probe.py'))['validate']
    helpers = runpy.run_path(str(source / 'linux/scripts/06-packaging/probe-compiler-defaults.py'))
    for prefix, mode in [('', 'default'), ('login-', 'login')]:
        result = json.loads((results / (prefix + 'cross-clang.json')).read_text())
        facts = result['facts']
        expected = validate_cross(facts, plan['expected_pins']['GCC_VERSION'], plan['expected_pins']['LLVM_RELEASE'], helpers, profile=subject['cpu_profile'])
        assert result['mode'] == mode and all(result[name] == value for name,value in expected.items())
        assert facts['baked_sha256'] == inv['expected_cross_baked_sha256']
        assert facts['environment'] == modes[prefix or 'default']['environment'], 'Cross checks changed the qualified native environment'
        assert facts['smoke']['stdout'] == (results / (prefix + 'cross-toolchain.log')).read_text()
        for name, row in facts['wrappers'].items():
            assert row['script_sha256'] == hashlib.sha256(row['script'].encode()).hexdigest()
        for language,name in [('c','native-wrapper-probe.c'), ('cxx','native-wrapper-probe.cc')]:
            assert facts['native_programs'][language]['source_sha256'] == inv['input_sha256']['inputs/' + name]
        if mode == 'default':
            assert all(value == baked_environment.get(key) for key,value in facts['environment'].items())
        cross_modes[mode] = result
proof = {"status": subject['qualification_status'], 'subject':subject,
         "observed_at": datetime.datetime.now(datetime.UTC).isoformat(), "source_revision": plan["source_revision"],
         "terminal_before_stop": terminal, "actual_container_id": cid, "actual_image_manifest": container["Image"],
         "image_config": inv["expected_config"], "native_facts": native["facts"], "compiler_defaults": defaults["facts"],
         "bare_load": loaded, "container_environment_matches_baked_image": True, "baked_script_bytes_match_source": True,
         "login_shell_selection_passed": True, "login_native_facts": modes["login-"]["native"]["facts"],
         "login_compiler_defaults": modes["login-"]["defaults"]["facts"], "login_environment": modes["login-"]["environment"],
         "scope": __doc__, "native_OCI_ancestry_still_required_before_SDK": not sdk_required,
         'native_OCI_ancestry_still_required_before_GPU_or_media':sdk_required, "publication": False,
         "results_sha256": {path.name: sha(path) for path in results.iterdir() if path.is_file()}}
proof.update(cross_wrapper_checks_required=cross_required, cross_wrapper_CPU_checks_passed=bool(cross_modes) and cross_required,
             cross_wrapper_modes=cross_modes if cross_required else {}, sdk_native_checks_required=sdk_required,
             sdk_native_CPU_checks_passed=bool(cross_modes) and sdk_required,
             sdk_native_modes=cross_modes if sdk_required else {})
assert not (out / "proof.json").exists()
save(out / "proof.json", proof)
run(["systemctl", "--user", "stop", args.unit])
stopped = state(args.unit)
assert stopped["ActiveState"] == "inactive" and stopped["MainPID"] == "0"
retained = json.loads((out / "retained-stop-cleanup.json").read_text())
assert retained["exit_status"] == 0 and retained["retain"] is True
run(["python3", str(source / "linux/scripts/cleanup-owned-containers.py"), "--engine", engine,
     "--owner-label", owner_label, "--run-id", inv["run_id"], "--cidfile", str(out / "container.cid"),
     "--output", str(out / "cleanup.json")])
cleanup = json.loads((out / "cleanup.json").read_text())
assert cleanup["exit_status"] == 0
rows = checked_inventory()
assert not any(inv["run_id"] in json.dumps(row) or cid.startswith(row["ID"]) or row["ID"].startswith(cid) for row in rows)
proof.update(stopped=stopped, retained_stop_cleanup=retained, cleanup=cleanup, independent_engine_query_exit_status=0, owned_container_absent=True)
save(out / "proof-stopped.json", proof)
print(json.dumps({"status": proof["status"], "manifest": container["Image"], "native_tools": 157, "cleanup": 0, "owned_absent": True}))
