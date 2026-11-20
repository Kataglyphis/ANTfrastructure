"""Deduplicate reviewed OCI bytes; configured JSON roots do not authenticate receipts or lock concurrent writers."""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import uuid
from collections import defaultdict
from pathlib import Path
from typing import Any

from host_commands import checked_output, engine_json_lines
from native_oci_layout import sha
from native_oci_seed import STAT_FIELDS, identity, plain_directory, plain_file
from source_ci.common import read, require, save, timestamp


def observe_idle(engine: str, directory: Path, phase: str) -> None:
    units = checked_output(
        [
            "systemctl",
            "--user",
            "list-units",
            "--no-legend",
            "--state=running",
            "webgpu-*",
            "rebuild-*",
        ]
    )
    require(not units.strip(), "An owned build or proof unit is running")
    rows = engine_json_lines(engine, directory / (phase + "-containers.json"))
    require(
        all(
            isinstance(row.get("Status"), str)
            and row["Status"].lower().startswith(("created", "exited", "dead"))
            for row in rows
        ),
        "A container is running or has unknown state",
    )
    records = json.loads(checked_output(["buildctl", "du", "--format", "{{json .}}"]))
    require(
        isinstance(records, list)
        and all(type(row.get("inUse")) is bool and not row["inUse"] for row in records),
        "BuildKit is active or its state is unknown",
    )


def identity_numbers(value: Any, bound: bool = False) -> set[int]:
    result: set[int] = set()
    if isinstance(value, dict):
        for key, child in value.items():
            selected = bound or any(
                token in str(key).lower()
                for token in ("ino", "identit", "ctime", "mtime")
            )
            result.update(identity_numbers(child, selected))
    elif isinstance(value, list):
        for child in value:
            result.update(identity_numbers(child, bound))
    elif bound and type(value) is int:
        result.add(value)
    elif bound and isinstance(value, str):
        result.update(int(item) for item in re.findall(r"(?<!\w)\d+(?!\w)", value))
    return result


def receipt_data(path: Path) -> tuple[bytes | None, str]:
    before = path.lstat()
    if path.is_symlink():
        link = os.readlink(path)
        try:
            data, fingerprint = receipt_data(path.resolve(strict=False))
        except FileNotFoundError:
            data, fingerprint = None, "missing"
        fingerprint = hashlib.sha256((link + "\0" + fingerprint).encode()).hexdigest()
    else:
        plain_file(path)
        data = path.read_bytes()
        fingerprint = hashlib.sha256(data).hexdigest()
    after = path.lstat()
    require(
        all(getattr(before, name) == getattr(after, name) for name in STAT_FIELDS),
        "Receipt changed during reading",
    )
    return data, fingerprint


def identity_key_present(data: bytes) -> bool:
    return any(
        match[2]
        and any(
            token in match[1].lower()
            for token in (b"ino", b"identit", b"ctime", b"mtime", b"\\u")
        )
        for match in re.finditer(rb'"((?:[^"\\]|\\.)*)"(\s*:)?', data)
    )


def receipt_protection(
    roots: list[Path], output: Path
) -> tuple[set[int], dict[str, str]]:
    protected: set[int] = set()
    fingerprints: dict[str, str] = {}
    for root in roots:
        plain_directory(root)
        for folder, directories, names in os.walk(
            root, followlinks=False, onerror=raise_walk_error
        ):
            directories[:] = [
                name
                for name in directories
                if name != ".git" and Path(folder, name) != output
            ]
            for name in names:
                if not name.endswith(".json"):
                    continue
                path = Path(folder, name)
                try:
                    data, fingerprint = receipt_data(path)
                except (AssertionError, OSError) as error:
                    raise ValueError(
                        f"Cannot inspect JSON receipt {path}: {error}"
                    ) from error
                fingerprints[str(path)] = fingerprint
                if data is None:
                    continue
                if not identity_key_present(data):
                    continue
                protected.update(identity_numbers(json.loads(data)))
    return protected, fingerprints


def raise_walk_error(error: OSError) -> None:
    raise error


def describe(
    path: Path, root: Path, cache: dict[tuple[int, ...], str]
) -> dict[str, Any]:
    require(
        path.is_absolute() and path.is_relative_to(root),
        "Blob escapes its allowed root",
    )
    plain_directory(path.parent)
    require(
        path.parent.name == "sha256"
        and path.parent.parent.name == "blobs"
        and re.fullmatch(r"[0-9a-f]{64}", path.name),
        "Not an OCI SHA256 blob path",
    )
    context = path.parents[2]
    for ancestor in (context, *context.parents):
        require(
            not ((ancestor / ".git").exists() or (ancestor / ".git").is_symlink()),
            "Selected blob belongs to a source checkout",
        )
        if ancestor == root:
            break
    require(
        read(context / "oci-layout") == {"imageLayoutVersion": "1.0.0"},
        "Invalid OCI layout",
    )
    index = read(context / "index.json")
    require(
        index["schemaVersion"] == 2 and bool(index["manifests"]), "Invalid OCI index"
    )
    before = path.lstat()
    require(
        stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid(),
        "Blob is not an owned regular file",
    )
    key = (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_mtime_ns,
        before.st_ctime_ns,
    )
    if key not in cache:
        cache[key] = sha(path)
    require(cache[key] == path.name, "Blob SHA256 differs from its name")
    after = path.lstat()
    require(
        (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        )
        == key,
        "Blob changed during hashing",
    )
    return {
        "path": str(path),
        "identity": identity(path, stable=True),
        "links": before.st_nlink,
        "allocated_bytes": before.st_blocks * 512,
        "parent_inode": path.parent.stat().st_ino,
    }


def grouping_key(row: dict[str, Any]) -> tuple[Any, ...]:
    return (
        Path(row["path"]).name,
        *(value for key, value in row["identity"].items() if key != "st_ino"),
    )


def select_groups(
    rows: list[dict[str, Any]], protected: set[int]
) -> tuple[list[dict[str, Any]], int]:
    groups: dict[tuple[Any, ...], dict[int, list[dict[str, Any]]]] = defaultdict(
        lambda: defaultdict(list)
    )
    for row in rows:
        groups[grouping_key(row)][row["identity"]["st_ino"]].append(row)
    result = []
    skipped = 0
    for inodes in groups.values():
        eligible = []
        for inode, aliases in inodes.items():
            if (
                inode in protected
                or any(row["parent_inode"] in protected for row in aliases)
                or any(row["links"] != len(aliases) for row in aliases)
            ):
                skipped += len(aliases)
            else:
                eligible.append(aliases)
        if len(eligible) < 2:
            continue
        eligible.sort(key=lambda aliases: aliases[0]["path"])
        result.append(
            {
                "keeper": eligible[0][0],
                "victims": [row for aliases in eligible[1:] for row in aliases],
                "expected_freed_bytes": sum(
                    aliases[0]["allocated_bytes"] for aliases in eligible[1:]
                ),
            }
        )
    return result, skipped


def authorize(path: Path, candidates_sha256: str) -> dict[str, str]:
    plain_file(path)
    record = read(path)
    require(
        "oci-archive-dedup" in record["allowed_actions"]
        and bool(record["owner_instruction"]),
        "Explicit OCI deduplication authorization is required",
    )
    require(
        record["candidates_sha256"] == candidates_sha256,
        "Authorization selects different candidates",
    )
    return {"path": str(path), "sha256": sha(path)}


def candidate_paths(review: Path, expected: str, root: Path) -> list[Path]:
    require(sha(review) == expected, "Candidate manifest digest differs")
    rows = read(review)["rows"]
    paths = [
        Path(item) for row in rows for inode in row["inodes"] for item in inode["paths"]
    ]
    require(
        bool(paths) and len(set(paths)) == len(paths),
        "Empty or repeated candidate paths",
    )
    require(
        all(path.is_relative_to(root) for path in paths),
        "Candidate path is outside the allowed root",
    )
    return paths


def make_plan(
    review: Path,
    expected: str,
    root: Path,
    roots: list[Path],
    directory: Path,
    authorization: Path,
    engine: str,
) -> dict[str, Any]:
    require(__debug__, "Optimization disables prerequisite assertions")
    plain_directory(root)
    require(
        not directory.exists() and not directory.is_symlink(),
        "Preserve existing proof output",
    )
    require(
        directory.is_absolute()
        and directory.parent.resolve(strict=True) == directory.parent,
        "Proof parent is not literal",
    )
    paths = candidate_paths(review, expected, root)
    require(
        not any(
            path.is_relative_to(directory) or directory.is_relative_to(path.parent)
            for path in paths
        ),
        "Proof output overlaps selected blobs",
    )
    authorization_record = authorize(authorization, expected)
    directory.mkdir()
    observe_idle(engine, directory, "preview")
    protected, receipts = receipt_protection(roots, directory)
    cache: dict[tuple[int, ...], str] = {}
    rows = [describe(path, root, cache) for path in paths]
    groups, skipped = select_groups(rows, protected)
    require(sha(review) == expected, "Candidates changed during preview")
    record = {
        "schema": 1,
        "status": "verified-OCI-dedup-preview-only",
        "observed_at": timestamp(),
        "directory": str(directory),
        "root": str(root),
        "receipt_roots": [str(path) for path in roots],
        "candidates": {"path": str(review), "sha256": expected},
        "authorization": authorization_record,
        "protected_receipt_sha256": receipts,
        "protected_identity_numbers": sorted(protected),
        "verified_paths": len(rows),
        "skipped_bound_or_external_paths": skipped,
        "groups": groups,
        "expected_freed_bytes": sum(group["expected_freed_bytes"] for group in groups),
        "modified": False,
        "scope": __doc__,
    }
    save(directory / "preview.json", record)
    return record


def check_plan(plan: dict[str, Any], directory: Path, engine: str) -> None:
    plain_directory(directory)
    require(
        plan["schema"] == 1
        and plan["status"] == "verified-OCI-dedup-preview-only"
        and plan["directory"] == str(directory),
        "Unexpected OCI preview",
    )
    require(
        not (directory / "apply-receipt.json").exists()
        and not (directory / "journal.jsonl").exists(),
        "Refusing a repeated application",
    )
    require(
        sha(Path(plan["candidates"]["path"])) == plan["candidates"]["sha256"],
        "Candidate input changed",
    )
    auth = authorize(Path(plan["authorization"]["path"]), plan["candidates"]["sha256"])
    require(auth == plan["authorization"], "Authorization changed")
    observe_idle(engine, directory, "apply")
    protected, receipts = receipt_protection(
        [Path(path) for path in plan["receipt_roots"]], directory
    )
    require(
        receipts == plan["protected_receipt_sha256"]
        and sorted(protected) == plan["protected_identity_numbers"],
        "Receipt protection changed; create a new preview",
    )
    cache: dict[tuple[int, ...], str] = {}
    for group in plan["groups"]:
        for expected in [group["keeper"], *group["victims"]]:
            actual = describe(Path(expected["path"]), Path(plan["root"]), cache)
            require(actual == expected, "Planned blob identity, bytes or links changed")


def replace_blob(source: Path, destination: Path) -> None:
    temporary = destination.with_name(".oci-dedup-" + uuid.uuid4().hex)
    try:
        os.link(source, temporary, follow_symlinks=False)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def apply_plan(
    preview: Path, expected: str, directory: Path, engine: str
) -> dict[str, Any]:
    require(__debug__, "Optimization disables prerequisite assertions")
    plain_file(preview)
    require(
        preview == directory / "preview.json",
        "Preview must belong to this proof directory",
    )
    require(sha(preview) == expected, "Preview digest differs")
    plan = read(preview)
    check_plan(plan, directory, engine)
    before = os.statvfs(directory)
    count = 0
    with (directory / "journal.jsonl").open("x") as journal:
        for group in plan["groups"]:
            source = Path(group["keeper"]["path"])
            for row in group["victims"]:
                destination = Path(row["path"])
                require(
                    identity(source, stable=True) == group["keeper"]["identity"],
                    "Keeper changed before link",
                )
                require(
                    identity(destination, stable=True) == row["identity"],
                    "Victim changed before link",
                )
                replace_blob(source, destination)
                count += 1
                journal.write(
                    json.dumps({"source": str(source), "destination": str(destination)})
                    + "\n"
                )
                journal.flush()
    verify_applied(plan, directory)
    after = os.statvfs(directory)
    result = {
        "status": "completed-reviewed-OCI-archive-dedup-only",
        "observed_at": timestamp(),
        "preview_sha256": expected,
        "replaced_paths": count,
        "groups": len(plan["groups"]),
        "expected_freed_bytes": plan["expected_freed_bytes"],
        "free_before_bytes": before.f_bavail * before.f_frsize,
        "free_after_bytes": after.f_bavail * after.f_frsize,
        "modified": count > 0,
        "scope": __doc__,
    }
    save(directory / "apply-receipt.json", result)
    return result


def verify_applied(plan: dict[str, Any], directory: Path) -> None:
    cache: dict[tuple[int, ...], str] = {}
    for group in plan["groups"]:
        keeper = group["keeper"]
        for row in [keeper, *group["victims"]]:
            actual = describe(Path(row["path"]), Path(plan["root"]), cache)
            require(
                actual["identity"] == keeper["identity"],
                "Linked bytes or stable metadata differ",
            )
    _, receipts = receipt_protection(
        [Path(path) for path in plan["receipt_roots"]], directory
    )
    require(receipts == plan["protected_receipt_sha256"], "A protected receipt changed")
