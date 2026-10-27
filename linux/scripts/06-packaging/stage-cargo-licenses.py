#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Stage original Cargo license files; this does not prove linkage or legal completeness.

The target-filtered normal dependency graph is conservative. Explicit policy entries
resolve missing, workspace and nested sources with a SHA-256 and source provenance.
The optional live Cargo tree includes normal and build dependencies. Neither selection
proves binary linkage; development dependencies, native libraries and corresponding-source
duties need separate inventories.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

from cargo_license_tree import (
    feature_arguments,
    live_toolchain,
    live_tree,
    resolve_tree,
)

MAX_FILE_BYTES = 8 * 1024 * 1024
MAX_TOTAL_BYTES = 64 * 1024 * 1024
COMPONENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.+-]*$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise TypeError(f"expected a JSON object: {path}")
    return value


def cargo_metadata(
    workspace: Path, target: str, feature_args: list[str]
) -> dict[str, Any]:
    command = [
        "cargo",
        "metadata",
        "--locked",
        "--offline",
        "--filter-platform",
        target,
        "--format-version",
        "1",
        *feature_args,
    ]
    result = subprocess.run(
        command, cwd=workspace, check=True, stdout=subprocess.PIPE, text=True
    )
    metadata = json.loads(result.stdout)
    if not isinstance(metadata, dict):
        raise TypeError("cargo metadata returned a non-object")
    return metadata


def normal_graph(metadata: dict[str, Any], root_name: str) -> list[dict[str, Any]]:
    packages = {package["id"]: package for package in metadata["packages"]}
    members = set(metadata["workspace_members"])
    roots = [
        item
        for item in packages.values()
        if item["name"] == root_name and item["id"] in members
    ]
    if len(roots) != 1:
        raise ValueError(
            f"expected exactly one workspace package named {root_name}, found {len(roots)}"
        )
    nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
    pending = [roots[0]["id"]]
    seen: set[str] = set()
    while pending:
        current = pending.pop()
        if current in seen:
            continue
        if current not in packages or current not in nodes:
            raise ValueError(f"Cargo graph is missing package or node: {current}")
        seen.add(current)
        for dependency in nodes[current]["deps"]:
            kinds = dependency["dep_kinds"]
            if not kinds:
                raise ValueError(f"Cargo dependency has no kind: {dependency['pkg']}")
            if any(kind["kind"] is None for kind in kinds):
                pending.append(dependency["pkg"])
    result = sorted(
        (packages[item] for item in seen),
        key=lambda item: (item["name"], item["version"], item["id"]),
    )
    keys = [package_key(item) for item in result]
    if len(keys) != len(set(keys)):
        raise ValueError(
            "multiple Cargo sources share a name and version; policy keys would be ambiguous"
        )
    return result


def package_key(package: dict[str, Any]) -> str:
    name, version = package["name"], package["version"]
    if (
        not isinstance(name, str)
        or not isinstance(version, str)
        or not COMPONENT.fullmatch(name)
        or not COMPONENT.fullmatch(version)
    ):
        raise ValueError(f"unsafe Cargo package name or version: {name!r} {version!r}")
    return f"{name}@{version}"


def safe_file(root: Path, relative: str) -> Path:
    if re.match(r"^[A-Za-z]:", relative) or relative.startswith(("\\\\", "//")):
        raise ValueError(f"unsafe license source path: {relative!r}")
    path = Path(relative.replace("\\", "/"))
    if (
        not relative
        or path.is_absolute()
        or any(part in ("..", ".") for part in path.parts)
    ):
        raise ValueError(f"unsafe license source path: {relative!r}")
    candidate = root / path
    current = root
    for part in path.parts:
        current /= part
        if current.is_symlink():
            raise ValueError(f"license source uses a symlink: {current}")
    if not candidate.is_file() or not candidate.resolve().is_relative_to(
        root.resolve()
    ):
        raise ValueError(f"license source is missing or outside its root: {candidate}")
    return candidate


def original_files(
    package: dict[str, Any],
) -> list[tuple[str, str, Path, str | None, str | None]]:
    manifest = Path(package["manifest_path"])
    if not manifest.is_file():
        raise ValueError(f"Cargo package manifest is missing: {manifest}")
    root = manifest.parent
    result: list[tuple[str, str, Path, str | None, str | None]] = []
    explicit = package.get("license_file")
    if explicit:
        candidate = Path(explicit)
        if candidate.is_absolute():
            try:
                explicit = candidate.relative_to(root).as_posix()
            except ValueError as error:
                raise ValueError(
                    f"license_file outside package root: {candidate}"
                ) from error
        result.append(("package", explicit, safe_file(root, explicit), None, None))
    for path in sorted(root.iterdir()):
        if path.name.lower().startswith(
            ("license", "licence", "copying", "notice")
        ) and (path.is_file() or path.is_symlink()):
            result.append(
                ("package", path.name, safe_file(root, path.name), None, None)
            )
    return result


def policy_files(
    package: dict[str, Any], workspace: Path, policy: dict[str, Any]
) -> list[tuple[str, str, Path, str | None, str | None]]:
    entry = policy.get(package_key(package), {})
    if not isinstance(entry, dict) or not isinstance(entry.get("files", []), list):
        raise TypeError(f"invalid policy entry: {package_key(package)}")
    result: list[tuple[str, str, Path, str | None, str | None]] = []
    for item in entry.get("files", []):
        if not isinstance(item, dict):
            raise TypeError(f"invalid policy source: {package_key(package)}")
        kind, relative = item.get("root"), item.get("path")
        digest, provenance = item.get("sha256"), item.get("provenance")
        if kind not in ("package", "workspace") or not isinstance(relative, str):
            raise ValueError(f"invalid policy path: {package_key(package)}")
        if (
            not isinstance(digest, str)
            or not SHA256.fullmatch(digest)
            or not isinstance(provenance, str)
            or not provenance.strip()
        ):
            raise ValueError(
                f"policy source needs a lowercase SHA-256 and provenance: {package_key(package)}"
            )
        root = Path(package["manifest_path"]).parent if kind == "package" else workspace
        path = safe_file(root, relative)
        result.append((kind, relative.replace("\\", "/"), path, provenance, digest))
    return result


def license_sources(
    package: dict[str, Any], workspace: Path, policy: dict[str, Any]
) -> list[tuple[str, str, Path, str | None, str | None]]:
    key = package_key(package)
    extras = policy_files(package, workspace, policy)
    license_expression = package.get("license")
    if not license_expression and not package.get("license_file"):
        raise ValueError(f"{key} has neither declared license nor license_file")
    if isinstance(license_expression, str) and re.search(
        r"\bAND\b", license_expression
    ):
        entry = policy.get(key, {})
        if not extras or entry.get("reviewed_expression") != license_expression:
            raise ValueError(
                f"{key} has a compound AND license; provide its reviewed expression and original sources"
            )
    sources = extras + original_files(package)
    if not sources:
        raise ValueError(
            f"{key} has no license file; provide original sources in policy"
        )
    if not any(
        not Path(relative).name.lower().startswith("notice")
        for _, relative, _, _, _ in sources
    ):
        raise ValueError(f"{key} has notices but no license text")
    return sources


def read_verified_source(path: Path, expected_digest: str | None) -> tuple[bytes, str]:
    if path.stat().st_size > MAX_FILE_BYTES:
        raise ValueError(f"license source is empty or too large: {path}")
    data = path.read_bytes()
    if not data.strip() or len(data) > MAX_FILE_BYTES:
        raise ValueError(f"license source is empty or too large: {path}")
    digest = hashlib.sha256(data).hexdigest()
    if expected_digest and digest != expected_digest:
        raise ValueError(f"policy source SHA-256 mismatch: {path}")
    return data, digest


def collect_sources(
    packages: list[dict[str, Any]], workspace: Path, policy: dict[str, Any]
) -> list[dict[str, Any]]:
    inventory: list[dict[str, Any]] = []
    total = 0
    for package in packages:
        key = package_key(package)
        sources = license_sources(package, workspace, policy)
        files: list[dict[str, Any]] = []
        destinations: set[str] = set()
        for kind, relative, path, provenance, expected_digest in sources:
            destination = f"{kind}/{Path(relative).as_posix()}"
            if destination in destinations:
                if expected_digest:
                    raise ValueError(
                        f"duplicate policy license destination: {key}/{destination}"
                    )
                continue
            destinations.add(destination)
            data, digest = read_verified_source(path, expected_digest)
            total += len(data)
            if total > MAX_TOTAL_BYTES:
                raise ValueError("Cargo license texts exceed the total size limit")
            files.append(
                {
                    "path": destination,
                    "data": data,
                    "sha256": digest,
                    "provenance": provenance,
                }
            )
        inventory.append({"key": key, "package": package, "files": files})
    return inventory


def publish_directory(staging: Path, output: Path) -> None:
    if os.name == "nt":
        os.rename(staging, output)
        return
    if not sys.platform.startswith("linux"):
        raise ValueError("atomic no-replace publication requires Linux or Windows")
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameat2
    rename.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    rename.restype = ctypes.c_int
    if rename(-100, os.fsencode(staging), -100, os.fsencode(output), 1) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(output))


def stage_inventory(
    inventory: list[dict[str, Any]],
    output: Path,
    target: str,
    root_name: str,
    selection: dict[str, Any],
) -> None:
    if output.exists() or output.is_symlink():
        raise ValueError(f"output already exists: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=".cargo-licenses-", dir=output.parent
    ) as temporary:
        staging = Path(temporary) / "payload"
        staging.mkdir()
        records: list[dict[str, Any]] = []
        for item in inventory:
            package = item["package"]
            copied: list[dict[str, Any]] = []
            for source in item["files"]:
                path = staging / item["key"] / source["path"]
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(source["data"])
                copied.append(
                    {
                        "path": path.relative_to(staging).as_posix(),
                        "sha256": source["sha256"],
                        "provenance": source["provenance"],
                    }
                )
            records.append(
                {
                    "name": package["name"],
                    "version": package["version"],
                    "id": package["id"],
                    "source": package.get("source"),
                    "repository": package.get("repository"),
                    "license": package.get("license"),
                    "target_kinds": sorted(
                        {
                            kind
                            for target in package.get("targets", [])
                            for kind in target.get("kind", [])
                        }
                    ),
                    "files": copied,
                }
            )
        manifest = {
            "target": target,
            "root_package": root_name,
            "scope": "Cargo dependency inventory; not proof of linkage or legal completeness",
            "selection": selection,
            "packages": records,
        }
        (staging / "manifest.json").write_text(
            json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
        publish_directory(staging, output)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", required=True, type=Path)
    parser.add_argument("--root-package", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--policy", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument(
        "--graph-scope",
        choices=("metadata-normal", "tree-normal-build"),
        default="metadata-normal",
    )
    parser.add_argument(
        "--features",
        action="append",
        default=[],
        help="Cargo feature selection; repeat to pass multiple values",
    )
    parser.add_argument("--all-features", action="store_true")
    parser.add_argument("--no-default-features", action="store_true")
    parser.add_argument(
        "--metadata",
        type=Path,
        help="read precomputed target-filtered metadata for offline fixtures",
    )
    args = parser.parse_args()
    try:
        workspace = args.workspace.resolve(strict=True)
        policy = load_json(args.policy)
        if policy.get("version") != 1 or not isinstance(policy.get("packages"), dict):
            raise ValueError("policy needs version 1 and a packages object")
        feature_args = feature_arguments(
            args.features, args.all_features, args.no_default_features
        )
        if args.metadata and (args.graph_scope != "metadata-normal" or feature_args):
            raise ValueError(
                "precomputed metadata is only supported for the default fixture scope and feature selection"
            )
        metadata = (
            load_json(args.metadata)
            if args.metadata
            else cargo_metadata(workspace, args.target, feature_args)
        )
        if Path(metadata["workspace_root"]).resolve() != workspace:
            raise ValueError("Cargo metadata belongs to a different workspace")
        normal = normal_graph(metadata, args.root_package)
        selected = normal
        if args.graph_scope == "tree-normal-build":
            tree = live_tree(workspace, args.target, args.root_package, feature_args)
            selected = resolve_tree(metadata, tree, args.root_package)
        selection = {
            "mode": args.graph_scope,
            "toolchain": live_toolchain()
            if not args.metadata
            else {"evidence": "fixture", "cargo_version": None, "rustc_host": None},
            "feature_arguments": feature_args,
            "edge_kinds": ["normal", "build"]
            if args.graph_scope == "tree-normal-build"
            else ["normal"],
            "metadata_normal_ids": [package["id"] for package in normal],
            "selected_ids": [package["id"] for package in selected],
        }
        inventory = collect_sources(selected, workspace, policy["packages"])
        stage_inventory(
            inventory, args.output_dir, args.target, args.root_package, selection
        )
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        json.JSONDecodeError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(
        f"PASS: staged original license files for {len(inventory)} Cargo packages in {args.output_dir}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
