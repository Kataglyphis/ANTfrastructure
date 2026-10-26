#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Report copied Bash and PowerShell units between a consumer and ANTfrastructure."""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from collections import defaultdict
from pathlib import Path, PurePosixPath

import verify_code_dupes as dupes

gate_scope = dupes.gate_scope

SCRIPT_PATHS = (":(glob)**/*.sh", ":(glob)**/*.ps1", ":(glob)**/*.psm1")
SYNC_PREFIX = "  OK      "


class HubReuseError(Exception):
    """A missing or invalid input must fail even in report mode."""


def _shared_check(root: Path, hub: Path) -> set[str]:
    """Use the canonical drift gate before excluding declared, synchronized copies."""
    if not (root / ".antfrastructure-shared.manifest").is_file():
        return set()
    bash = hub / "shared/config/sync-shared-config.sh"
    pwsh = hub / "shared/config/Sync-SharedConfig.ps1"
    commands = (("bash", ["bash", str(bash), "--repo-root", str(root), "--check"]),
                ("pwsh", ["pwsh", "-NoProfile", "-File", str(pwsh),
                          "-RepoRoot", str(root), "-Check"]))
    # Windows bash may enter WSL, which cannot interpret native checkout paths.
    if sys.platform == "win32":
        commands = commands[::-1]
    for tool, command in commands:
        if not shutil.which(tool):
            continue
        script = bash if tool == "bash" else pwsh
        if not script.is_file():
            raise HubReuseError(f"missing shared-config checker: {script}")
        try:
            result = subprocess.run(command, capture_output=True, text=True,
                                    encoding="utf-8", check=False)
        except OSError:
            continue
        if result.returncode:
            details = (result.stdout + result.stderr).strip()
            raise HubReuseError(f"shared-config check failed ({result.returncode}):\n{details}")
        return _synced_paths(result.stdout)
    raise HubReuseError("the shared-config manifest needs bash or pwsh for drift validation")


def _synced_paths(output: str) -> set[str]:
    paths = set()
    for line in output.splitlines():
        if not line.startswith(SYNC_PREFIX):
            continue
        rel = line[len(SYNC_PREFIX):].strip().replace("\\", "/")
        parts = PurePosixPath(rel).parts
        if not rel or rel.startswith("/") or ".." in parts or re.match(r"^[A-Za-z]:", rel):
            raise HubReuseError(f"shared-config checker returned an unsafe path: {rel!r}")
        paths.add(rel)
    return paths


def _scripts(root: Path, synced: set[str]) -> list[tuple[Path, str]]:
    rels = gate_scope.tracked(root, SCRIPT_PATHS, exclude=tuple(dupes.SKIP_DIRS))
    files = []
    for rel in rels:
        parts = PurePosixPath(rel).parts
        if rel in synced or any(part in dupes.SKIP_DIRS for part in parts[:-1]):
            continue
        if any(marker.casefold() in parts[-1].casefold()
               for marker in dupes.SKIP_NAME_MARKERS):
            continue
        kind = dupes.file_kind(parts[-1])
        if kind not in ("shell", "ps"):
            continue
        path = root / rel
        if not path.resolve().is_relative_to(root):
            raise HubReuseError(f"tracked script resolves outside its checkout: {rel}")
        files.append((path, kind))
    return files


def _matches(consumer: dupes.Owners, consumer_lines: dupes.UnitLines,
             hub_files: list[tuple[Path, str]], hub: Path,
             ) -> tuple[list[tuple[int, int, dupes.Unit, dupes.Unit]], int]:
    hub_index, _, _, hub_lines, _ = dupes.index_units(
        hub_files, root=hub, only_shingles=set(consumer))
    matching = set(consumer) & set(hub_index)
    owners: dupes.Owners = defaultdict(set)
    for sh in matching:
        owners[sh].update((f"consumer/{rel}", line) for rel, line in consumer[sh])
        owners[sh].update((f"hub/{rel}", line) for rel, line in hub_index[sh])
    shared, _, _, suppressed = dupes.collect_shared(owners, set(), {})
    lines = {(f"consumer/{rel}", n): body for (rel, n), body in consumer_lines.items()}
    lines.update({(f"hub/{rel}", n): body for (rel, n), body in hub_lines.items()})
    findings = []
    for (a, b), count in shared.items():
        if count <= dupes.DEFAULT_THRESHOLD or a[0].split("/", 1)[0] == b[0].split("/", 1)[0]:
            continue
        consumer_unit, hub_unit = (a, b) if a[0].startswith("consumer/") else (b, a)
        run = dupes.longest_common_run(lines[consumer_unit], lines[hub_unit])
        findings.append((count, run, consumer_unit, hub_unit))
    findings.sort(key=lambda row: (-row[1], -row[0], row[2], row[3]))
    return findings, suppressed


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, help="consumer Git checkout root")
    parser.add_argument("--hub", required=True, help="ANTfrastructure Git checkout root")
    parser.add_argument("--report-only", action="store_true",
                        help="write findings but keep the verdict advisory; broken inputs still fail")
    return parser.parse_args()


def main() -> int:
    args = _arguments()
    try:
        root = Path(gate_scope.resolve_root(args.root, args.root)).resolve()
        hub = Path(gate_scope.resolve_root(args.hub, args.hub)).resolve()
        if root == hub:
            print("hub reuse: self comparison skipped (root and hub are the same checkout)")
            return 0
        synced = _shared_check(root, hub)
        consumer_files = _scripts(root, synced)
        consumer, _, _, consumer_lines, _ = dupes.index_units(consumer_files, root=root)
        hub_files = _scripts(hub, set())
        if not hub_files:
            raise HubReuseError(f"no tracked Bash or PowerShell scripts in hub {hub}")
        if not consumer:
            print(f"hub reuse: 0 overlapping unit pair(s) in 0 consumer unit(s), "
                  f"{len(consumer_files)} consumer and {len(hub_files)} hub script(s); "
                  "hub token scan skipped; "
                  f"{len(synced)} declared synced copy/copies skipped")
            return 0
        findings, suppressed = _matches(consumer, consumer_lines, hub_files, hub)
    except (gate_scope.ScopeError, HubReuseError, OSError, UnicodeError) as exc:
        print(f"ERROR: hub reuse scan: {exc}", file=sys.stderr)
        return 2
    print(f"hub reuse: {len(findings)} overlapping unit pair(s) in {len(consumer_lines)} consumer "
          f"unit(s), {len(consumer_files)} consumer and {len(hub_files)} hub script(s); "
          f"{len(synced)} declared synced copy/copies skipped; "
          f"{suppressed} idiom shingle(s) suppressed")
    for count, run, consumer_unit, hub_unit in findings:
        print(f"  {count} shared shingles, {run} consecutive line(s)")
        print(f"    {consumer_unit[0]}:{consumer_unit[1]}")
        print(f"    {hub_unit[0]}:{hub_unit[1]}")
    if findings and not args.report_only:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
