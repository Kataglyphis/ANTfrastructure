"""Audit the native source-test archive and unchanged coverage policy; no package or GPU execution is proved."""

import argparse
import hashlib
import json
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path
from typing import Any

from source_ci.common import fingerprint, git, read, require, save, timestamp


def coverage_row(archive: zipfile.ZipFile, row: dict[str, Any], minima: dict[str, float]) -> dict[str, Any]:
    module = row["Module"]
    analyzed, executed = row["Analyzed"], row["Executed"]
    require(analyzed > 0 and 0 <= executed <= analyzed, "Vacuous command coverage")
    ratio = executed * 100 / analyzed
    require(abs(ratio - row["Percent"]) < 1e-6 and row["MinimumPercent"] == minima[module] and ratio >= minima[module], "Coverage floor mismatch")
    member = row["ReportPath"].replace("\\", "/").rsplit("/", 1)[-1]
    xml = ET.fromstring(archive.read(member))
    valid, covered = int(xml.attrib["lines-valid"]), int(xml.attrib["lines-covered"])
    require(xml.tag == "coverage" and valid > 0 and 0 < covered <= valid and abs(covered / valid - float(xml.attrib["line-rate"])) < 1e-6,
            "Coverage XML is malformed or vacuous")
    require(any(item.get("filename", "").replace("\\", "/").rsplit("/", 1)[-1] == module for item in xml.findall(".//class")),
            "Coverage XML lacks its declared module")
    return {"module": module, "command_coverage_percent": ratio, "minimum_percent": minima[module],
            "analyzed_commands": analyzed, "executed_commands": executed, "xml_member": member,
            "xml_lines_valid": valid, "xml_lines_covered": covered}


def source_summary(archive: zipfile.ZipFile, minima: dict[str, float]) -> tuple[str, dict[str, Any], list[dict[str, Any]]]:
    names = archive.namelist()
    require(len(names) == len(set(names)), "Duplicate archive member")
    summaries = [name for name in names if Path(name).name.startswith("summary-") and name.endswith(".json")]
    require(len(summaries) == 1, "Missing or ambiguous test summary")
    summary = json.loads(archive.read(summaries[0]))
    require(summary["Total"] == summary["Passed"] and summary["Passed"] >= summary["MinTests"] > 0, "Failed tests or unmet floor")
    require(summary["ExitCode"] == summary["PesterFailures"] == summary["FailedCount"] == 0 and summary["FloorMet"] and summary["CoverageFloorMet"], "Source-test verdict failed")
    require(all(summary[key] == [] for key in ("Failed", "Skipped", "Broken", "CoverageFailures")), "Failed, skipped or broken source tests")
    coverage = summary["Coverage"]
    require(minima and len(coverage) == len(minima) and {row["Module"] for row in coverage} == set(minima), "Coverage target list changed")
    return summaries[0], summary, [coverage_row(archive, row, minima) for row in coverage]


def run(args: argparse.Namespace) -> None:
    artifact = read(args.api)
    prior = read(args.prior_proof)
    digest = "sha256:" + fingerprint(args.zip)
    require(digest == artifact["digest"] and args.zip.stat().st_size == artifact["size_in_bytes"] and not artifact["expired"], "Artifact bytes or identity differ")
    head = artifact["workflow_run"]["head_sha"]
    policy = "windows/scripts/tests/Invoke-Tests.ps1"
    old = git(args.root, "show", prior["head"] + ":" + policy)
    new = git(args.root, "show", head + ":" + policy)
    require(old == new, "Previously audited coverage policy changed; re-audit targets")
    minima = {row["module"]: row["minimum_percent"] for row in prior["coverage"]}
    require(len(minima) == len(prior["coverage"]), "Duplicate prior coverage targets")
    with zipfile.ZipFile(args.zip) as archive:
        member, summary, rows = source_summary(archive, minima)
    proof = {"status": "passed-native-source-test-artifact-audit", "scope": __doc__, "observed_at": timestamp(),
             "head": head, "run_id": artifact["workflow_run"]["id"], "artifact_id": artifact["id"], "digest": digest,
             "bytes": args.zip.stat().st_size, "summary_member": member, "total": summary["Total"], "passed": summary["Passed"],
             "exit_code": 0, "failed": [], "skipped": [], "broken": [], "coverage_failures": [],
             "coverage": rows, "coverage_policy_sha256": hashlib.sha256(new).hexdigest()}
    save(args.output, proof)
