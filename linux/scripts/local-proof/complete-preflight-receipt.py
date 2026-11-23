#!/usr/bin/env python3
"""Assemble already-sealed source evidence; this does not authenticate provenance or prove image/GPU acceptance."""

from __future__ import annotations

import argparse
import collections
import datetime
import hashlib
import json
import re
import runpy
import shlex
import subprocess
import sys
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from proof_types import Json


def read(path: Path) -> Json:
    return json.loads(path.read_text())


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def checked(command: list[str]) -> str:
    return subprocess.run(command, capture_output=True, text=True, check=True, timeout=60).stdout


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--directory", type=Path, required=True)
parser.add_argument("--reference", type=Path, required=True)
parser.add_argument("--engine", default=str(Path.home() / ".local/bin/nerdctl"))
parser.add_argument("--name", default="complete-preflight-proof")
args = parser.parse_args()
assert re.fullmatch(r"[A-Za-z0-9_.-]+", args.name)
out = args.directory.resolve()
proof_path = out / (args.name + ".json")
query_path = out / (args.name + "-engine-query.json")
assert not proof_path.exists() and not query_path.exists()
record = read(out / "run.json")
assert record["status"] == "passed" and record["command_exit_status"] == record["cleanup_exit_status"] == 0, "preflight run is not terminal successful"
assert record["interrupted_exit_status"] is None and record["finished_at"]
invocation = read(out.parent / (out.name + "-invocation.json"))
assert invocation["revision"] == record["source_revision"] and invocation["run_id"] == record["owner_run_id"]
source = Path(record["source_snapshot"])
assert checked(["git", "-C", str(source), "rev-parse", "HEAD"]).strip() == record["source_revision"]
assert not checked(["git", "-C", str(source), "status", "--porcelain"]).strip()
reference = read(args.reference)
assert reference["status"] == "passed-complete-Linux-source-preflight-only"
assert (source / "linux/scripts/preflight.sh").read_bytes() == (Path(reference["source_snapshot"]) / "linux/scripts/preflight.sh").read_bytes(), "Canonical preflight groups changed; inspect before reusing the reference"
groups = reference["all_default_preflight_groups"]
assert groups and len(groups) == len(set(groups)) == reference["actual_preflight_group_count"]
raw = (out / "preflight.log").read_bytes()
text = re.sub(r"\x1b\[[0-9;]*m", "", raw.decode())
actual = collections.Counter(re.findall(r"^✓ (.+)$", text, re.MULTILINE))
assert all(actual[name] == 1 for name in groups) and "All preflight checks passed." in text
summaries = re.findall(r"^All linux script test suites passed \((\d+) suites, (\d+) assertions\)\.$", text, re.MULTILINE)
assert len(summaries) == 1
suites, assertions = map(int, summaries[0])
names = re.findall(r"^== (test-[^/\n]+\.sh) ==$", text, re.MULTILINE)
assert suites > 0 and assertions > 0 and len(names) == len(set(names)) == suites
seal = read(out / "mutation-proof-stopped.json")
terminal = seal["terminal"]
assert seal["status"] == "passed-mutation-unit-only" and seal["unit"] == terminal["Id"] == invocation["unit"]
assert terminal["LoadState"] == "loaded" and terminal["MainPID"] == terminal["ExecMainStatus"] == "0"
assert terminal["Result"] == "success" and int(terminal["ExecMainExitTimestampMonotonic"]) > 0
assert seal["stopped"]["MainPID"] == "0" and seal["stopped"]["ActiveState"] == "inactive"
manifest, mutations = source / "docs/scripts/mutations.json", out / "mutations-only.log"
assert seal["inputs"] == {str(manifest): digest(manifest), str(mutations): digest(mutations)}
sys.path.insert(0, str(source / "linux/scripts"))
count = runpy.run_path(str(source / "linux/scripts/seal-mutation-unit.py"))["mutation_ids"](manifest, mutations, False)
assert count == seal["unique_actual_mutations"] == invocation["full_registry"]
extraction = read(out / "mutator-extraction.json")
assert extraction["source_sha256"] == hashlib.sha256(raw).hexdigest()
assert raw[extraction["start_byte"]:extraction["end_byte_exclusive"]] == mutations.read_bytes()
assert digest(mutations) == extraction["mutation_job_sha256"]
cleanup_commands = [value.split("ExecStopPost=", 1)[1] for value in invocation["command"]
                    if re.match(r"^(?:--property=|-p)?ExecStopPost=", value)]
assert len(cleanup_commands) == 1
cleanup_argv = shlex.split(cleanup_commands[0])
assert cleanup_argv[cleanup_argv.index("--run-id") + 1] == record["owner_run_id"]
cleanup = read(Path(cleanup_argv[cleanup_argv.index("--output") + 1]))
assert cleanup["exit_status"] == 0 and cleanup["run_id"] == record["owner_run_id"]
query = subprocess.run([args.engine, "ps", "-a", "--format", "{{json .}}"], capture_output=True, text=True, check=False, timeout=60)
query_path.write_text(json.dumps({"returncode": query.returncode, "stdout": query.stdout, "stderr": query.stderr}, indent=2) + chr(10))
assert query.returncode == 0
cid = (out / "container.cid").read_text().strip()
assert re.fullmatch(r"[0-9a-f]{64}", cid)
rows = [json.loads(line) for line in query.stdout.splitlines() if line.strip()]
assert not any(record["owner_run_id"] in json.dumps(row) or row.get("Names") == record["container"] or cid.startswith(row["ID"]) or row["ID"].startswith(cid) for row in rows)
proof = {**record, "status": "passed-complete-Linux-source-preflight-only", "observed_at": datetime.datetime.now(datetime.UTC).isoformat(), "all_default_preflight_groups": groups, "actual_preflight_group_count": len(groups), "script_suites": suites, "script_assertions": assertions, "executed_script_suites": names, "actual_full_registry_mutations": count, "mutator_job_extraction": str(out / "mutator-extraction.json"), "exact_mutation_seal": str(out / "mutation-proof-stopped.json"), "unit_stopped_after_seal": True, "independent_engine_query_exit_status": 0, "owned_container_absent": True, "cleanup_record": cleanup, "scope": "All default source groups, every actual registry mutation and all logged suites at the exact frozen source commit. No compiled WASM factory, image matrix or finished GPU/consumer acceptance.", "verification_note": "Each canonical outer group passes exactly once; exact mutation-job bytes; unchanged strict whole-manifest validator replays the sealed inputs.", "publication": False}
with proof_path.open("x") as stream:
    json.dump(proof, stream, indent=2)
    stream.write(chr(10))
print(json.dumps({"status": proof["status"], "groups": len(groups), "mutations": count, "suites": suites, "assertions": assertions, "owned_absent": True}))
