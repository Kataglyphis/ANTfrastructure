# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Resolve a live Cargo tree to unambiguous metadata package IDs, not binary linkage."""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path
from typing import Any

FEATURES = re.compile(r"^[A-Za-z0-9_+./?,\-]+$")
TREE_LINE = re.compile(
    r"^([A-Za-z0-9][A-Za-z0-9_.+\-]*) v([A-Za-z0-9][A-Za-z0-9_.+\-]*)(?: \(.*\))?$"
)


def live_toolchain() -> dict[str, str]:
    cargo = subprocess.run(
        ["cargo", "--version"], check=True, stdout=subprocess.PIPE, text=True
    ).stdout.strip()
    rustc = subprocess.run(
        [os.environ.get("RUSTC", "rustc"), "-vV"],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    ).stdout
    hosts = [
        line.removeprefix("host: ")
        for line in rustc.splitlines()
        if line.startswith("host: ")
    ]
    if (
        not re.fullmatch(r"cargo [0-9][^\r\n]*", cargo)
        or len(hosts) != 1
        or not re.fullmatch(r"[A-Za-z0-9_.+\-]+", hosts[0])
    ):
        raise ValueError(
            "Cargo or rustc did not report an unambiguous version and host"
        )
    return {"evidence": "live", "cargo_version": cargo, "rustc_host": hosts[0]}


def feature_arguments(
    features: list[str], all_features: bool, no_default: bool
) -> list[str]:
    args: list[str] = []
    for value in features:
        if not FEATURES.fullmatch(value) or any(
            not part or part.startswith("-") for part in value.split(",")
        ):
            raise ValueError(f"invalid Cargo feature selection: {value!r}")
        args.extend(("--features", value))
    if all_features:
        args.append("--all-features")
    if no_default:
        args.append("--no-default-features")
    return args


def resolve_tree(
    metadata: dict[str, Any], output: str, root_name: str
) -> list[dict[str, Any]]:
    packages = metadata["packages"]
    members = set(metadata["workspace_members"])
    roots = [p for p in packages if p["name"] == root_name and p["id"] in members]
    if len(roots) != 1:
        raise ValueError(f"expected exactly one workspace root {root_name!r}")
    candidates: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for package in packages:
        candidates.setdefault((package["name"], package["version"]), []).append(package)
    selected: dict[str, dict[str, Any]] = {}
    lines = output.splitlines()
    if not lines:
        raise ValueError("Cargo tree returned no packages")
    for index, line in enumerate(lines):
        match = TREE_LINE.fullmatch(line)
        if match is None:
            raise ValueError(f"unexpected Cargo tree output: {line!r}")
        matches = candidates.get((match.group(1), match.group(2)), [])
        if len(matches) != 1:
            raise ValueError(
                f"Cargo tree package {match.group(1)}@{match.group(2)} has {len(matches)} metadata matches"
            )
        package = matches[0]
        if index == 0 and package["id"] != roots[0]["id"]:
            raise ValueError(
                "Cargo tree did not start with the requested workspace root"
            )
        selected[package["id"]] = package
    return sorted(selected.values(), key=lambda p: (p["name"], p["version"], p["id"]))


def live_tree(
    workspace: Path, target: str, root_name: str, feature_args: list[str]
) -> str:
    command = [
        "cargo",
        "tree",
        "--locked",
        "--offline",
        "--target",
        target,
        "--package",
        root_name,
        "--edges",
        "normal,build",
        "--prefix",
        "none",
        "--format",
        "{p}",
        "--color",
        "never",
        *feature_args,
    ]
    return subprocess.run(
        command, cwd=workspace, check=True, stdout=subprocess.PIPE, text=True
    ).stdout
