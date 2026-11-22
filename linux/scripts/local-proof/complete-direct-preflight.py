#!/usr/bin/env python3
"""Assemble closed direct-wrapper source evidence; no re-sealing, cleanup, provenance authentication or image/GPU proof."""

from __future__ import annotations

import argparse
import collections
import hashlib
import re
import runpy
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Any, TypedDict

SCRIPTS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS))

from runtime_terminal_evidence import successful_unit
from source_ci.common import fingerprint, read, require, save, timestamp

PRESERVER = runpy.run_path(str(SCRIPTS / "preserve-consumer-sources.py"))
MUTATION_IDS = runpy.run_path(str(SCRIPTS / "seal-mutation-unit.py"))["mutation_ids"]


class EngineQuery(TypedDict):
    filter: str
    returncode: int
    stdout: str
    stderr: str


def source_subject(invocation: dict[str, Any]) -> tuple[Path, tuple]:
    source = Path(invocation["source"]).resolve(strict=True)
    frozen = read(Path(invocation["source_selection"]))
    snapshot = PRESERVER["working_snapshot"](source)
    require(snapshot[0] == invocation["source_base"] == frozen["selected_base"], "Source revision differs")
    require(str(source) == frozen["destination"], "Frozen destination differs")
    require(hashlib.sha256(snapshot[1]).hexdigest() == invocation["source_index_sha256"] == frozen["index_sha256"], "Source index differs")
    require(snapshot[2] == frozen["versioned_paths"], "Source files or modes differ")
    empty = hashlib.sha256(b"").hexdigest()
    require(invocation["source_patch_sha256"] == frozen["patch_sha256"] == empty, "Source patch is not empty")
    PRESERVER["verify_tree"](source, snapshot[0], invocation["source_index_sha256"])
    return source, snapshot


def execution_counts(source: Path, reference: dict[str, Any], invocation: dict[str, Any], raw: bytes) -> dict[str, Any]:
    require(reference["status"] == "passed-complete-Linux-source-preflight-only", "Reference did not pass")
    require((source / "linux/scripts/preflight.sh").read_bytes()
            == (Path(reference["source_snapshot"]) / "linux/scripts/preflight.sh").read_bytes(), "Canonical preflight changed")
    groups = reference["all_default_preflight_groups"]
    require(groups and len(groups) == len(set(groups)) == reference["actual_preflight_group_count"]
            == invocation["expected_default_groups"], "Canonical group inventory differs")
    text = re.sub(r"\x1b\[[0-9;]*m", "", raw.decode())
    passes = collections.Counter(re.findall(r"^✓ (.+)$", text, re.MULTILINE))
    headings = collections.Counter(re.findall(r"^== (.+) ==$", text, re.MULTILINE))
    require(all(passes[name] == headings[name] == 1 for name in groups), "Missing or repeated canonical group")
    require("All preflight checks passed." in text and not re.search(r"^✗ ", text, re.MULTILINE), "Preflight failed")
    summaries = re.findall(r"^All linux script test suites passed \((\d+) suites, (\d+) assertions\)\.$", text, re.MULTILINE)
    require(len(summaries) == 1, "Missing unique suite summary")
    suites, assertions = map(int, summaries[0])
    names = re.findall(r"^== (test-[^/\n]+\.sh) ==$", text, re.MULTILINE)
    discovered = {path.name for path in (source / "linux/scripts/tests").glob("test-*.sh")}
    require(suites == len(names) == len(set(names)) == invocation["expected_script_suites"]
            and set(names) == discovered and assertions > 0, "Suite execution inventory differs")
    return {"all_default_preflight_groups": groups, "actual_preflight_group_count": len(groups),
            "script_suites": suites, "script_assertions": assertions, "executed_script_suites": names}


def sealed_execution(directory: Path, source: Path, invocation: dict[str, Any], raw: bytes) -> dict[str, Any]:
    seal = read(directory / "mutation-proof-stopped.json")
    require(seal["status"] == "passed-mutation-unit-only" and seal["unit"] == invocation["unit"], "Mutation seal identity differs")
    successful_unit(seal["terminal"], invocation["unit"])
    require(seal["stopped"]["MainPID"] == "0" and seal["stopped"]["ActiveState"] == "inactive", "Unit was not stopped")
    require((directory / "compiler-cache/exit-status.txt").read_text() == "command_status=0\ncache_stats_status=0\n", "Command or cache capture failed")
    manifest, mutations = source / "docs/scripts/mutations.json", directory / "mutator.log"
    require(seal["inputs"] == {str(path): fingerprint(path) for path in (manifest, mutations)}, "Sealed mutation inputs changed")
    count = MUTATION_IDS(manifest, mutations, False)
    require(count == seal["unique_actual_mutations"] == invocation["full_registry_count"], "Mutation count differs")
    extraction = read(directory / "mutator-extraction.json")
    require(extraction["source_sha256"] == hashlib.sha256(raw).hexdigest()
            and raw[extraction["start_byte"]:extraction["end_byte_exclusive"]] == mutations.read_bytes()
            and extraction["mutation_job_sha256"] == fingerprint(mutations), "Mutation slice differs")
    return {"actual_full_registry_mutations": count, "terminal": seal["terminal"], "stopped": seal["stopped"]}


def closed_container(directory: Path, invocation: dict[str, Any]) -> str:
    cid = (directory / "container.cid").read_text().strip()
    require(re.fullmatch(r"[0-9a-f]{64}", cid) and re.fullmatch(r"[0-9a-f]{32}", invocation["run_id"]), "Invalid ownership identity")
    cleanup = read(directory / "cleanup.json")
    require(cleanup["exit_status"] == 0 and cleanup["finished_at"], "Original cleanup did not succeed")
    require(cleanup["run_id"] == invocation["run_id"] and cleanup["owner_label"] == invocation["owner_label"]
            and cleanup["cidfile"] == str(directory / "container.cid"), "Original cleanup identity differs")
    commands = [value.split("=", 1)[1] for value in invocation["command"] if value.startswith("ExecStopPost=")]
    require(len(commands) == 1, "Missing unique original cleanup hook")
    arguments = shlex.split(commands[0])
    for flag, expected in (("--run-id", invocation["run_id"]), ("--owner-label", invocation["owner_label"]),
                           ("--cidfile", str(directory / "container.cid")), ("--output", str(directory / "cleanup.json"))):
        require(arguments.count(flag) == 1 and arguments[arguments.index(flag) + 1] == expected, "Cleanup hook differs: " + flag)
    require(directory.stat().st_mode & 0o777 == 0o700 and (directory / "reports").stat().st_mode & 0o777 == 0o755, "Report permissions are not closed")
    return cid


def observed_container(directory: Path, invocation: dict[str, Any], cid: str) -> None:
    rows = read(directory / "live-container-inspect-1.json")
    require(len(rows) == 1 and rows[0]["Id"] == cid, "Observed container differs")
    container = rows[0]
    require(container["Image"] == invocation["image"].rsplit("@", 1)[-1], "Observed image differs")
    require(container["Config"]["Labels"].get(invocation["owner_label"]) == invocation["run_id"], "Observed owner differs")
    environment = container["Config"]["Env"]
    require(environment.count("ISOLATED_PREFLIGHT_REVISION=" + invocation["source_base"]) == 1, "Observed revision differs")
    for name in ("PREFLIGHT_ONLY", "PREFLIGHT_SKIP", "PREFLIGHT_MUTATION_SHARD", "PREFLIGHT_MUTATION_COSTS"):
        require([value for value in environment if value.startswith(name + "=")] == [name + "="], "Filtered preflight: " + name)
    mounts = [row for row in container["Mounts"] if row["Destination"] == "/source"]
    require(len(mounts) == 1 and mounts[0]["Source"] == invocation["source"] and mounts[0]["RW"] is False, "Observed source mount differs")


def absence(engine: str, directory: Path, invocation: dict[str, Any], cid: str, name: str) -> Path:
    rows: list[EngineQuery] = []
    for value in ("id=" + cid, "label=" + invocation["owner_label"] + "=" + invocation["run_id"]):
        command = [engine, "ps", "-a", "-q", "--no-trunc", "--filter", value]
        result = subprocess.run(command, capture_output=True, text=True, check=False, timeout=60)
        rows.append({"filter": value, "returncode": result.returncode, "stdout": result.stdout, "stderr": result.stderr})
    output = directory / (name + "-engine-query.json")
    save(output, {"observed_at": timestamp(), "queries": rows})
    require(all(row["returncode"] == 0 and not row["stdout"].strip() for row in rows), "Fresh engine absence query failed")
    return output


def assemble(directory: Path, reference_path: Path, engine: str, name: str) -> dict[str, Any]:
    require(re.fullmatch(r"[A-Za-z0-9_.-]+", name), "Invalid output name")
    require(not any((directory / suffix).exists() for suffix in (name + ".json", name + "-engine-query.json")), "Refusing existing receipt outputs")
    invocation = read(directory / "invocation.json")
    require(invocation["full_preflight"] is True and invocation["launch_status"] == 0, "Not a successful direct full-preflight launch")
    source, snapshot = source_subject(invocation)
    paths = [directory / value for value in ("invocation.json", "unit.log", "mutation-proof-stopped.json", "mutator.log",
             "mutator-extraction.json", "cleanup.json", "live-container-inspect-1.json", "compiler-cache/exit-status.txt",
             "compiler-cache/cache-stats.json")]
    paths += [reference_path, Path(invocation["source_selection"])]
    require(all(path.is_file() and not path.is_symlink() for path in paths), "Missing regular evidence inputs")
    hashes = {str(path): fingerprint(path) for path in paths}
    require(isinstance(read(directory / "compiler-cache/cache-stats.json").get("stats"), dict), "Invalid captured cache statistics")
    raw = (directory / "unit.log").read_bytes()
    counts = execution_counts(source, read(reference_path), invocation, raw)
    execution = sealed_execution(directory, source, invocation, raw)
    cid = closed_container(directory, invocation)
    observed_container(directory, invocation, cid)
    query = absence(engine, directory, invocation, cid, name)
    require(PRESERVER["working_snapshot"](source) == snapshot and all(fingerprint(Path(path)) == digest for path, digest in hashes.items()), "Evidence changed during assembly")
    proof = {"status": "passed-complete-Linux-source-preflight-only", "observed_at": timestamp(), "source_snapshot": str(source),
             "source_revision": invocation["source_base"], "source_index_sha256": invocation["source_index_sha256"],
             "source_patch_sha256": invocation["source_patch_sha256"], "unit": invocation["unit"], **counts, **execution,
             "inputs_sha256": hashes, "independent_engine_query": str(query), "independent_engine_query_exit_status": 0,
             "owned_container_absent": True, "unit_stopped_after_seal": True, "command_exit_status": 0,
             "cache_capture_exit_status": 0, "cleanup_exit_status": 0, "owner_run_id": invocation["run_id"],
             "exact_mutation_seal": str(directory / "mutation-proof-stopped.json"),
             "mutator_job_extraction": str(directory / "mutator-extraction.json"),
             "cleanup_record": read(directory / "cleanup.json"),
             "direct_wrapper_evidence": True, "publication": False, "scope": __doc__}
    save(directory / (name + ".json"), proof)
    return proof


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--engine", default=str(Path.home() / ".local/bin/nerdctl"))
    parser.add_argument("--name", default="complete-preflight-proof")
    args = parser.parse_args()
    proof = assemble(args.directory.resolve(strict=True), args.reference.resolve(strict=True), args.engine, args.name)
    print(f"Complete direct source preflight: {proof['actual_preflight_group_count']} groups, {proof['actual_full_registry_mutations']} mutations")


if __name__ == "__main__":
    main()
