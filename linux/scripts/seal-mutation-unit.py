#!/usr/bin/env python3
"""Seal executed mutation IDs and stop one terminal successful user unit; no CI, image or GPU proof is implied."""

import argparse
import collections
import re
from pathlib import Path

from host_commands import checked_output
from source_ci.common import fingerprint, read, require, save, timestamp

FIELDS = "Id,LoadState,ActiveState,SubState,MainPID,ExecMainStatus,Result,ExecMainExitTimestampMonotonic"


def unit_state(unit: str) -> dict[str, str]:
    result = checked_output(["systemctl", "--user", "show", f"--property={FIELDS}", unit])
    return dict(line.split("=", 1) for line in result.splitlines() if "=" in line)


def mutation_ids(manifest: Path, log: Path, selected: bool) -> int:
    entries = read(manifest)
    expected = collections.Counter(entry["id"] for entry in entries)
    text = log.read_text(encoding="utf-8")
    actual = collections.Counter(re.findall(r"^\[\d+/\d+\]\s+bites\s+(\S+)\s", text, re.MULTILINE))
    require(entries and all(count == 1 for count in expected.values()), "Empty or duplicate source mutation IDs")
    require(actual == expected and all(count == 1 for count in actual.values()), f"Mutation IDs differ: missing={expected - actual}, extra={actual - expected}")
    marker = f"coverage: proved {len(entries)} of {len(entries)}: the whole manifest"
    success = "OK: every recorded mutation is caught by its tests"
    if selected:
        marker = f"coverage: proved {len(entries)} of {len(entries)} selected; 0 delegated to CI, 0 skipped by this host;"
        success = f"OK: all {len(entries)} proved here are caught; that is not the whole manifest"
    require(marker in text and success in text and "FAIL:" not in text, "Missing mutation success or recorded failures")
    return len(actual)


def run(args: argparse.Namespace) -> None:
    require(not args.output.exists(), "Refusing to overwrite an earlier seal")
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.@:-]*\.service", args.unit), "Pass an explicit user service name")
    count = mutation_ids(args.manifest, args.log, args.selected)
    before = unit_state(args.unit)
    require(before.get("LoadState") == "loaded" and before.get("Id") == args.unit, "Unit is not loaded with the requested identity")
    require(before["MainPID"] == before["ExecMainStatus"] == "0" and before["Result"] == "success"
            and before["ActiveState"] in ("active", "inactive") and before["SubState"] in ("exited", "dead")
            and int(before["ExecMainExitTimestampMonotonic"]) > 0, f"Unit is not terminal successful: {before}")
    proof = {"observed_at": timestamp(), "unit": args.unit, "terminal": before, "unique_actual_mutations": count,
             "inputs": {str(path): fingerprint(path) for path in (args.manifest, args.log)}, "scope": __doc__, "status": "terminal-observed-stop-pending"}
    save(args.output, proof)
    checked_output(["systemctl", "--user", "stop", args.unit])
    after = unit_state(args.unit)
    require(after.get("MainPID") == "0" and after.get("ActiveState") == "inactive", f"Unit did not stop: {after}")
    save(args.output.with_name(args.output.stem + "-stopped.json"), {**proof, "status": "passed-mutation-unit-only", "stopped": after})
    print(f"Sealed {count} unique mutations; {args.unit} stopped")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--unit", required=True)
    for name in ("manifest", "log", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--selected", action="store_true")
    run(parser.parse_args())


if __name__ == "__main__":
    main()
