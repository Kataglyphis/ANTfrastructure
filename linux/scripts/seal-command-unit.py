#!/usr/bin/env python3
"""Seal a cache-captured command and its owned cleanup; caller markers do not prove build, GPU or cache acceptance."""

from __future__ import annotations

import argparse
import re
import runpy
from pathlib import Path

from host_commands import checked_output
from runtime_terminal_evidence import successful_unit
from source_ci.common import fingerprint, read, require, save, timestamp

unit_state = runpy.run_path(str(Path(__file__).with_name("seal-mutation-unit.py")))["unit_state"]


def run(args: argparse.Namespace) -> None:
    directory = args.directory.resolve(strict=True)
    output = directory / "command-proof.json"
    stopped_output = directory / "command-proof-stopped.json"
    cleanup_path = directory / "cleanup.json"
    require(not output.exists() and not stopped_output.exists(), "Refusing an existing command seal")
    require(not cleanup_path.exists(), "Refusing to rerun an existing exclusive cleanup")
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.@:-]*\.service", args.unit), "Invalid explicit unit")
    paths = [directory / name for name in ("invocation.json", "unit.log", "compiler-cache/exit-status.txt", "compiler-cache/cache-stats.json")]
    require(all(path.is_file() and not path.is_symlink() for path in paths), "Missing or linked command evidence")
    invocation = read(paths[0])
    require(invocation["unit"] == args.unit, "Invocation unit differs")
    require(re.fullmatch(r"[0-9a-f]{32}", invocation["run_id"]), "Invalid invocation run ID")
    lines = paths[1].read_text(encoding="utf-8").splitlines()
    require(args.success_marker and all(marker and marker in lines for marker in args.success_marker), "Missing exact command success marker")
    require(paths[2].read_text() == "command_status=0\ncache_stats_status=0\n", "Command or cache capture did not succeed")
    statistics = read(paths[3])
    require(isinstance(statistics.get("stats"), dict), "Invalid captured cache statistics")
    terminal = successful_unit(unit_state(args.unit), args.unit)
    proof = {"status": "terminal-command-observed-stop-pending", "observed_at": timestamp(), "unit": args.unit,
             "terminal": terminal, "success_markers": args.success_marker, "cache_statistics": statistics,
             "inputs_sha256": {str(path): fingerprint(path) for path in paths},
             "scope": __doc__, "acceptance_claimed": False}
    save(output, proof)
    checked_output(["systemctl", "--user", "stop", args.unit])
    stopped = unit_state(args.unit)
    require(stopped.get("MainPID") == "0" and stopped.get("ActiveState") == "inactive", "Command unit did not stop")
    cleanup = read(cleanup_path)
    require(cleanup.get("exit_status") == 0 and cleanup.get("run_id") == invocation["run_id"]
            and cleanup.get("owner_label") == invocation["owner_label"], "Owned cleanup failed or identity differs")
    save(stopped_output, {**proof, "status": "passed-command-unit-lifecycle-only", "stopped": stopped,
                          "cleanup": cleanup, "cleanup_sha256": fingerprint(cleanup_path)})
    print(f"Sealed command and owned cleanup; {args.unit} stopped")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--unit", required=True)
    parser.add_argument("--success-marker", action="append", required=True)
    run(parser.parse_args())


if __name__ == "__main__":
    main()
