#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Preserve selected original source notices; this proves neither binary linkage nor complete licence/source closure."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import runpy
import subprocess
import tomllib
from pathlib import Path
from typing import Any

NOTICE_PATHS = {
    "monorepo": (
        "LICENSE",
        "subprojects/gstreamer/COPYING",
        "subprojects/gst-plugins-base/COPYING",
        "subprojects/gst-plugins-good/COPYING",
        "subprojects/gst-plugins-bad/COPYING",
        "subprojects/gst-plugins-ugly/COPYING",
        "subprojects/gst-libav/COPYING",
    ),
    "rust": (
        "LICENSE-APACHE",
        "LICENSE-MIT",
        "LICENSE-MPL-2.0",
        "video/gtk4/LICENSE-MPL-2.0",
    ),
}
CONTEXT_PATHS = {
    "monorepo": (
        "subprojects/gst-plugins-rs.wrap",
        "subprojects/gstreamer/README.static-linking",
    ),
    "rust": ("Cargo.toml", "video/gtk4/Cargo.toml"),
}


_shared = runpy.run_path(str(Path(__file__).parents[4] / "01-core/source_originals.py"))
if _shared.get("SOURCE_ORIGINALS_API") != 1:
    raise ValueError("Unsupported original-file companion")
for _name in (
    "require",
    "unique_object",
    "plain_parents",
    "original_bytes",
    "write_originals",
):
    if not callable(_shared.get(_name)):
        raise TypeError("Missing original-file companion export: " + _name)
require = _shared["require"]
unique_object = _shared["unique_object"]
plain_parents = _shared["plain_parents"]
original_bytes = _shared["original_bytes"]
write_originals = _shared["write_originals"]
GSTREAMER_SOURCE_NOTICES_API = 1


def git(tree: Path, *arguments: str) -> bytes:
    return subprocess.run(
        ["git", "-C", str(tree), *arguments], check=True, capture_output=True
    ).stdout


def selected_policy(path: Path, version: str, kind: str) -> dict[str, Any]:
    policy = json.loads(original_bytes(path), object_pairs_hook=unique_object)
    require(
        isinstance(policy, dict) and policy.get("schema") == 1,
        "Invalid notice policy schema",
    )
    require(
        policy.get("release") == version,
        "GStreamer version differs from reviewed notice policy",
    )
    profile = policy[kind]
    require(isinstance(profile, dict), "Invalid source notice profile")
    require(
        re.fullmatch(r"[0-9a-f]{40}", profile["commit"]) is not None,
        "Invalid reviewed source commit",
    )
    expected = set(NOTICE_PATHS[kind] + CONTEXT_PATHS[kind])
    require(
        isinstance(profile["files"], dict) and set(profile["files"]) == expected,
        "Incomplete selected original paths",
    )
    for value in profile["files"].values():
        require(
            isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None,
            "Invalid original SHA256",
        )
    return profile


def source_revision(
    tree: Path, profile: dict[str, Any], version: str, kind: str
) -> str:
    plain_parents(tree / ".source-root")
    require(
        git(tree, "rev-parse", "--show-toplevel").decode().removesuffix("\n")
        == str(tree),
        "Source Git root differs",
    )
    revision = git(tree, "rev-parse", "--verify", "HEAD").decode().strip()
    require(
        revision == profile["commit"], "Source commit differs from reviewed release"
    )
    tag = version if kind == "monorepo" else "gstreamer-" + version
    selected = (
        git(tree, "rev-parse", "--verify", "refs/tags/" + tag + "^{commit}")
        .decode()
        .strip()
    )
    require(selected == revision, "Source release tag differs from checked out commit")
    return revision


def selected_originals(
    tree: Path, profile: dict[str, Any], kind: str
) -> tuple[dict[str, bytes], dict[str, bytes]]:
    originals = {}
    working_context = {}
    for relative, expected in profile["files"].items():
        data = original_bytes(tree / relative)
        if relative in CONTEXT_PATHS[kind]:
            working_context[relative] = data
            data = git(tree, "show", "HEAD:" + relative)
        require(
            hashlib.sha256(data).hexdigest() == expected,
            "Original SHA256 differs: " + relative,
        )
        require(
            git(tree, "show", "HEAD:" + relative) == data,
            "Original differs from its Git source: " + relative,
        )
        originals[relative] = data
    return originals, working_context


def rust_package(
    originals: dict[str, bytes], profile: dict[str, Any]
) -> dict[str, str]:
    workspace = tomllib.loads(originals["Cargo.toml"].decode())
    package = tomllib.loads(originals["video/gtk4/Cargo.toml"].decode())["package"]
    require(
        package["name"] == "gst-plugin-gtk4"
        and package["version"] == {"workspace": True},
        "GTK4 package identity differs",
    )
    version = workspace["workspace"]["package"]["version"]
    require(version == profile["gtk4_package_version"], "GTK4 package version differs")
    require(
        package["license"] == profile["gtk4_license_expression"],
        "GTK4 license expression differs",
    )
    return {
        "name": package["name"],
        "version": version,
        "license_expression": package["license"],
    }


def preserve(
    destination: Path,
    originals: dict[str, bytes],
    working_context: dict[str, bytes],
    metadata: dict[str, Any],
    patch: bytes,
) -> None:
    payloads = dict(originals)
    payloads.update(
        ("working-context/" + name, data) for name, data in working_context.items()
    )
    payloads["source.patch"] = patch
    payloads["source-record.json"] = (json.dumps(metadata, indent=2) + "\n").encode()
    write_originals(destination, payloads)


def stage(
    source: Path, destination: Path, policy: Path, version: str, kind: str
) -> dict[str, Any]:
    source, destination, policy = (
        source.absolute(),
        destination.absolute(),
        policy.absolute(),
    )
    require(
        not destination.is_relative_to(source), "Destination must be outside source"
    )
    profile = selected_policy(policy, version, kind)
    revision = source_revision(source, profile, version, kind)
    originals, working_context = selected_originals(source, profile, kind)
    patch = git(source, "diff", "HEAD", "--binary", "--full-index")
    require(len(patch) <= 8 * 1024 * 1024, "Oversized source patch")
    repository = (
        "GStreamer/gstreamer" if kind == "monorepo" else "GStreamer/gst-plugins-rs"
    )
    metadata = {
        "status": "selected-original-source-notices-preserved",
        "kind": kind,
        "gstreamer_release": version,
        "source_commit": revision,
        "source_url": "https://github.com/" + repository + "/tree/" + revision,
        "policy_sha256": hashlib.sha256(original_bytes(policy)).hexdigest(),
        "source_patch_sha256": hashlib.sha256(patch).hexdigest(),
        "files": {
            name: {
                "sha256": hashlib.sha256(data).hexdigest(),
                "bytes": len(data),
                "kind": "original-notice"
                if name in NOTICE_PATHS[kind]
                else "source-context",
            }
            for name, data in originals.items()
        },
        "binary_linkage_or_complete_license_source_closure_proven": False,
        "untracked_source_files_included": False,
    }
    if kind == "rust":
        metadata["gtk4_package"] = rust_package(working_context, profile)
    metadata["working_context_sha256"] = {
        name: hashlib.sha256(data).hexdigest() for name, data in working_context.items()
    }
    preserve(destination, originals, working_context, metadata, patch)
    return metadata


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--kind", choices=tuple(NOTICE_PATHS), required=True)
    parser.add_argument(
        "--policy", type=Path, default=Path(__file__).with_name("original-notices.json")
    )
    args = parser.parse_args()
    try:
        record = stage(
            args.source, args.destination, args.policy, args.version, args.kind
        )
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        subprocess.SubprocessError,
    ) as error:
        parser.exit(
            1, "GStreamer original notice staging refused: " + str(error) + "\n"
        )
    print(
        json.dumps(
            {
                "status": record["status"],
                "kind": record["kind"],
                "source_commit": record["source_commit"],
            }
        )
    )


if __name__ == "__main__":
    main()
