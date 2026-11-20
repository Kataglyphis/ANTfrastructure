#!/usr/bin/env python3
"""Seal real red/green LLVM loader replay; candidate PATH is not fresh-image acceptance."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
out = args.output.resolve()
inv = json.loads((out / "invocation.json").read_text())
assert inv["owner_label"] == "org.kataglyphis.native-llvm-loader-replay"
engine = str(Path.home() / ".local/bin/nerdctl")


def checked(argv: list[str]) -> str:
    return subprocess.run(argv, capture_output=True, text=True, timeout=60, check=True).stdout


def state() -> dict[str, str]:
    raw = checked(["systemctl", "--user", "show", inv["unit"], "-p", "LoadState", "-p", "ActiveState", "-p", "SubState", "-p", "MainPID", "-p", "Result", "-p", "ExecMainStatus"])
    return dict(line.split("=", 1) for line in raw.splitlines() if "=" in line)


before = state()
assert before["LoadState"] == "loaded" and before["ActiveState"] == "active" and before["SubState"] == "exited"
assert before["MainPID"] == before["ExecMainStatus"] == "0" and before["Result"] == "success"
cid = (out / "container.cid").read_text().strip()
raw = checked([engine, "inspect", cid])
(out / "container-inspect.json").write_text(raw)
actual = json.loads(raw)[0]
assert actual["Id"] == cid and actual["Image"] == inv["expected_manifest"]
assert actual["Config"]["Labels"][inv["owner_label"]] == inv["run_id"]
assert actual["State"]["Running"] is False and actual["State"]["ExitCode"] == 0
results = out / "results"
original, native, defaults, old_load, new_load = [json.loads((results / name).read_text()) for name in ("original-native.json", "candidate-native.json", "candidate-defaults.json", "original-loaded.json", "candidate-loaded.json")]
assert (results / "original-native-status.txt").read_bytes() == b"1\n"
assert original["status"] == "failed" and original["error"].startswith("native LLVM shared library loses default loader lookup:")
assert native["status"] == "passed-native-llvm-tool-and-loader-selection-only"
assert native["facts"] == {"native_prefix": "/opt/llvm-target-amd64", "native_tool_count": 157, "llvm_config_version": "23.1.5", "native_library_sonames": ["libLLVM.so.23.1"]}
assert all(row["dynamic"]["returncode"] == 0 and row["soname"] == "libLLVM.so.23.1" and row["cache_winner"] == row["source"] for row in native["libraries"])
assert all(defaults["facts"][name]["version"] == "16.2.0" and defaults["facts"][name]["march"] == "x86-64-v3" and defaults["facts"][name]["mtune"] == "generic" and defaults["facts"][name]["v3_defines"] == ["AVX2", "FMA", "BMI2"] for name in ("cc", "c++", "gcc", "g++"))
assert all(defaults["facts"][name]["version"] == "23.1.5" for name in ("clang", "clang++"))
assert old_load["status"] == new_load["status"] == "passed-bare-soname-mapping-only"
assert len(old_load["loaded"]) == len(new_load["loaded"]) == 1
assert Path(old_load["loaded"][0]["path"]).is_relative_to("/usr/lib")
assert Path(new_load["loaded"][0]["path"]).is_relative_to("/opt/llvm-target-amd64/lib")
source_sha = (results / "source-library-sha256.txt").read_text().split()[0]
assert new_load["loaded"][0]["sha256"] == source_sha != old_load["loaded"][0]["sha256"]
assert (results / "native-conf.txt").read_bytes() == b"/opt/llvm-target-amd64/lib\n"
for filename in ("probe-compiler-defaults.py", "llvm-loader-path.sh"):
    assert hashlib.sha256((out / filename).read_bytes()).hexdigest() == inv["input_sha256"][filename]
    assert (out / filename).read_bytes() == (Path(inv["source_owner"]) / "linux/scripts/06-packaging" / filename).read_bytes()
proof = {"status": "passed-real-original-red-source-SONAME-loader-replay-only", "observed_at": datetime.datetime.now(datetime.UTC).isoformat(), "terminal_before_stop": before, "actual_container_id": cid, "actual_image_manifest": actual["Image"], "original_native_gate_status": 1, "original_error": original["error"], "candidate_native_facts": native["facts"], "candidate_default_facts": defaults["facts"], "bare_load_before": old_load, "bare_load_after": new_load, "source_library_sha256": source_sha, "probe_bytes_match_current_owner": True, "input_sha256": inv["input_sha256"], "results_sha256": {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in results.iterdir() if path.is_file()}, "sdk_parent_admitted": False, "fresh_rebuilt_image_qualification": False, "scope": inv["scope"], "publication": False}
assert not (out / "proof.json").exists()
(out / "proof.json").write_text(json.dumps(proof, indent=2) + "\n")
checked(["systemctl", "--user", "stop", inv["unit"]])
after = state()
assert after["MainPID"] == "0" and after["ActiveState"] == "inactive"
cleanup = json.loads((out / "cleanup.json").read_text())
assert cleanup["exit_status"] == 0
query = subprocess.run([engine, "ps", "-a", "--format", "{{json .}}"], capture_output=True, text=True, timeout=60, check=False)
(out / "independent-engine-query.json").write_text(json.dumps({"returncode": query.returncode, "stdout": query.stdout, "stderr": query.stderr}, indent=2) + "\n")
assert query.returncode == 0
rows = [json.loads(line) for line in query.stdout.splitlines() if line.strip()]
assert not any(inv["run_id"] in json.dumps(row) or cid.startswith(row["ID"]) or row["ID"].startswith(cid) for row in rows)
proof.update(stopped=after, cleanup=cleanup, independent_engine_query_exit_status=0, owned_container_absent=True)
(out / "proof-stopped.json").write_text(json.dumps(proof, indent=2) + "\n")
print(json.dumps({"status": proof["status"], "before": old_load["loaded"][0]["path"], "after": new_load["loaded"][0]["path"], "cleanup": 0, "owned_absent": True}))
