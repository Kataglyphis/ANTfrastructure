#!/usr/bin/env python3
"""Retire copied package staging from an owned container; supplied host observations do not authenticate callers or exclude future writers."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from source_ci.common import fingerprint, read, require, timestamp

FORBIDDEN = {".git", ".gitmodules", ".venv", ".cargo", ".cache", "ccache", "sccache", "cargo-home", "target"}
SELECTED = {"oxidant", "oxidant.AppDir", "deb"}


def validate_observation(plan: dict[str, Any]) -> None:
    observed = plan["observation"]
    require(0 <= time.time() - observed["observed_unix"] <= 120, "Require fresh host observations")
    state = observed["unit"]
    require(state["Id"] == plan["unit"], "Observed producer identity differs")
    quiet = state["MainPID"] == state["ControlPID"] == "0" and (
        state["LoadState"] == "not-found" or state["ActiveState"] in {"inactive", "failed"}
    )
    require(quiet, "Producer must be closed, including its stop work")
    require(observed["mount_conflicts"] == [] and observed["nested_mounts"] == [], "Preserve registered or mounted staging")
    queries = observed["queries"]
    expected = {"id=" + plan["CID"], "label=" + plan["owner_label"] + "=" + plan["run_id"]}
    require(len(queries) == 2 and {q["filter"] for q in queries} == expected, "Require exact CID and owner queries")
    require(all(type(q["exit_status"]) is int and q["exit_status"] == 0 and q["stdout"] == q["stderr"] == "" for q in queries), "Producer container absence is unproved")


def validate_subject(plan: dict[str, Any], root: Path) -> dict[str, Any]:
    require(plan["schema"] == 1, "Unsupported staging admission schema")
    token = plan["run_id"]
    require(re.fullmatch(r"[0-9a-f]{32}", token) is not None, "Invalid producer nonce")
    require(re.fullmatch(r"[0-9a-f]{64}", plan["CID"]) is not None, "Invalid full producer CID")
    require(plan["owner_label"] == "org.kataglyphis.current-rust-packages", "Select only the recorded package producer")
    require(re.fullmatch(r"/home/[^/]+/gpu/run-tmp/amd-package-" + token + r"/package-work", plan["host_staging"]) is not None, "Select only private AMD package staging")
    require(plan["closed_main_pid"] == plan["closed_control_pid"] == 0, "Saved producer is not terminal")
    require(plan["cache_status"] == plan["producer_cleanup_status"] == 0, "Preserve incomplete producer cleanup")
    require(type(plan["producer_status"]) is int and plan["producer_status"] >= 0, "Missing raw producer status")
    require(not root.is_symlink() and root.is_dir(), "Require a literal staging directory")
    identity = root.stat()
    require([identity.st_dev, identity.st_ino] == plan["staging_identity"], "Staging mount identity differs")
    names = {entry.name for entry in root.iterdir()}
    require(SELECTED <= names <= SELECTED | {"home"}, "Preserve unknown staging entries")
    require(all((root / name).is_dir() and not (root / name).is_symlink() for name in SELECTED), "Copied staging roots must be directories")
    return {key: plan[key] for key in ("unit", "run_id", "CID", "owner_label", "host_staging", "staging_identity", "invocation_sha256", "terminal_proof_sha256")}


def verify_archives(plan: dict[str, Any], directory: Path) -> list[dict[str, Any]]:
    records = plan["archives"]
    require(len(records) == 3 and len({r["name"] for r in records}) == 3, "Retain all three distinct package archives")
    kinds = set()
    for record in records:
        name = record["name"]
        require(re.fullmatch(r"oxidant[-_][A-Za-z0-9_.+-]+", name) is not None, "Invalid retained archive name")
        kinds.add("tar" if name.endswith(".tar.gz") else Path(name).suffix)
        archive = directory / name
        require(stat.S_ISREG(archive.lstat().st_mode) and record["bytes"] > 0, "Retain regular nonempty archives")
        require(archive.stat().st_size == record["bytes"] and fingerprint(archive) == record["sha256"], "Retained package bytes differ")
    require(kinds == {"tar", ".deb", ".AppImage"}, "Retain TAR, DEB and AppImage archives")
    return records


def tree(root: Path, protected_names: bool) -> list[dict[str, Any]]:
    if not root.exists() and not root.is_symlink():
        return []
    paths = [root, *sorted(root.rglob("*"))] if root.is_dir() and not root.is_symlink() else [root]
    records = []
    for path in paths:
        relative = path.relative_to(root).as_posix()
        require(not protected_names or FORBIDDEN.isdisjoint(Path(relative).parts), "Preserve source or cache entries")
        info = path.lstat()
        row = {"relative": relative, "mode": stat.S_IMODE(info.st_mode), "device": info.st_dev, "inode": info.st_ino, "mtime_ns": info.st_mtime_ns}
        if stat.S_ISREG(info.st_mode):
            require(info.st_nlink == 1, "Preserve shared file inodes")
            row.update(kind="file", bytes=info.st_size, allocated=info.st_blocks * 512, sha256=fingerprint(path))
        elif stat.S_ISDIR(info.st_mode):
            row.update(kind="directory")
        elif stat.S_ISLNK(info.st_mode):
            row.update(kind="link", target=os.readlink(path))
        else:
            raise ValueError("Preserve special staging files")
        records.append(row)
    return records


def execute(plan: dict[str, Any], root: Path, archives: Path, output: Path, preview: dict[str, Any] | None = None) -> dict[str, Any]:
    require(not output.exists() and not output.is_symlink(), "Preserve existing retirement evidence")
    require(not output.is_relative_to(root) and not output.is_relative_to(archives), "Keep evidence outside retained inputs")
    validate_observation(plan)
    subject = validate_subject(plan, root)
    retained = verify_archives(plan, archives)
    selected = {name: tree(root / name, True) for name in sorted(SELECTED)}
    require(all(any(row["kind"] == "file" for row in rows) for rows in selected.values()), "Copied staging is empty")
    preserved_home = tree(root / "home", False)
    snapshot = {"subject": subject, "archives": retained, "selected": selected, "preserved_home": preserved_home}
    signature = hashlib.sha256(json.dumps(snapshot, sort_keys=True).encode()).hexdigest()
    allocated = sum(row.get("allocated", 0) for rows in selected.values() for row in rows)
    status = "preview-only"
    if preview is not None:
        require(preview["status"] == "preview-only" and preview["snapshot_sha256"] == signature, "Changed or already-applied retirement preview")
        require(shutil.rmtree.avoids_symlink_attacks, "Require descriptor-based directory removal")
        descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            current = os.fstat(descriptor)
            require([current.st_dev, current.st_ino] == plan["staging_identity"], "Staging root changed before removal")
            for name in sorted(SELECTED):
                shutil.rmtree(name, dir_fd=descriptor)
            require(SELECTED.isdisjoint(os.listdir(descriptor)), "Copied staging removal is incomplete")
        finally:
            os.close(descriptor)
        require(tree(root / "home", False) == preserved_home, "Unselected private cache changed")
        verify_archives(plan, archives)
        status = "retired-copied-package-staging-only"
    result = {"status": status, "observed_at": timestamp(), "snapshot_sha256": signature, "allocated_regular_bytes": allocated, "snapshot": snapshot, "scope": __doc__}
    with output.open("x") as stream:
        json.dump(result, stream, indent=2)
        stream.write("\n")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--apply-preview", type=Path)
    args = parser.parse_args()
    preview = read(args.apply_preview) if args.apply_preview is not None else None
    result = execute(read(args.plan), Path("/staging"), Path("/archives"), args.output, preview)
    print(json.dumps({key: result[key] for key in ("status", "allocated_regular_bytes", "snapshot_sha256")}))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Package staging retirement refused: {error}", file=sys.stderr)
        raise SystemExit(2) from error
