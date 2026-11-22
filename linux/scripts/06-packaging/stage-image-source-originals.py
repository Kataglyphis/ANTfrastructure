#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Stage selected image source originals; no binary association, signature or complete licence/source closure proof."""

from __future__ import annotations

import argparse
import hashlib
import json
import runpy
import stat
from pathlib import Path
from typing import Any

GSTREAMER_CONTRACT = (
    Path(__file__).parents[1]
    / "03-media/build/gstreamer/common/stage-original-notices.py"
)
_gst = runpy.run_path(str(GSTREAMER_CONTRACT))
if _gst.get("GSTREAMER_SOURCE_NOTICES_API") != 1:
    raise ValueError("Unsupported GStreamer notice companion")
for _name in (
    "require",
    "unique_object",
    "plain_parents",
    "original_bytes",
    "write_originals",
    "selected_policy",
    "rust_package",
):
    if not callable(_gst.get(_name)):
        raise TypeError("Missing GStreamer notice companion export: " + _name)
require = _gst["require"]
unique_object = _gst["unique_object"]
plain_parents = _gst["plain_parents"]
original_bytes = _gst["original_bytes"]
write_originals = _gst["write_originals"]


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_json(path: Path) -> dict[str, Any]:
    value = json.loads(original_bytes(path), object_pairs_hook=unique_object)
    require(isinstance(value, dict), "Expected a JSON object: " + str(path))
    return value


def exact_tree(root: Path, names: set[str]) -> None:
    plain_parents(root / ".tree-root")
    actual = set()
    for path in root.rglob("*"):
        mode = path.lstat().st_mode
        require(
            stat.S_ISDIR(mode) or stat.S_ISREG(mode),
            "Linked or special notice tree member",
        )
        if stat.S_ISREG(mode):
            actual.add(path.relative_to(root).as_posix())
    require(actual == names, "Missing or unexpected source-original tree members")


def gcc_originals(prefix: Path, version: str, policy_file: Path) -> dict[str, bytes]:
    policy = read_json(policy_file)
    require(
        policy.get("schema") == 1 and policy.get("release") == version,
        "GCC version differs from reviewed notice policy",
    )
    require(
        set(policy["files"]) == {"COPYING3", "COPYING.RUNTIME"},
        "Incomplete GCC notice policy",
    )
    root = prefix / "share/licenses/gcc-runtime"
    names = {"COPYING3", "COPYING.RUNTIME", "source.sha512", "source.url"}
    exact_tree(root, names)
    payloads = {name: original_bytes(root / name) for name in sorted(names)}
    for name, expected in policy["files"].items():
        require(sha(payloads[name]) == expected, "GCC original SHA256 differs: " + name)
    archive = "gcc-" + version + ".tar.xz"
    checksum = policy["archive_sha512"] + "  " + archive + "\n"
    require(
        payloads["source.sha512"] == checksum.encode(),
        "GCC source checksum record differs",
    )
    url = "https://gcc.gnu.org/pub/gcc/releases/gcc-" + version + "/" + archive + "\n"
    require(payloads["source.url"] == url.encode(), "GCC source URL record differs")
    return {"gcc-runtime/" + name: data for name, data in payloads.items()}


def gst_record(
    root: Path, policy: Path, version: str, kind: str
) -> tuple[dict[str, Any], dict[str, Any]]:
    profile = _gst["selected_policy"](policy, version, kind)
    record = read_json(root / "source-record.json")
    repository = "gstreamer" if kind == "monorepo" else "gst-plugins-rs"
    expected = {
        "status": "selected-original-source-notices-preserved",
        "kind": kind,
        "gstreamer_release": version,
        "source_commit": profile["commit"],
        "source_url": "https://github.com/GStreamer/"
        + repository
        + "/tree/"
        + profile["commit"],
        "policy_sha256": sha(original_bytes(policy)),
    }
    require(
        all(record.get(name) == value for name, value in expected.items()),
        "GStreamer source record identity differs",
    )
    require(
        record.get("binary_linkage_or_complete_license_source_closure_proven") is False
        and record.get("untracked_source_files_included") is False,
        "GStreamer source record exceeds selected scope",
    )
    require(
        isinstance(record.get("files"), dict)
        and set(record["files"]) == set(profile["files"]),
        "GStreamer original record paths differ",
    )
    return profile, record


def gst_payloads(
    root: Path, profile: dict[str, Any], record: dict[str, Any], kind: str
) -> dict[str, bytes]:
    payloads = {}
    for name, expected in profile["files"].items():
        data = original_bytes(root / name)
        role = (
            "original-notice"
            if name in _gst["NOTICE_PATHS"][kind]
            else "source-context"
        )
        require(sha(data) == expected, "GStreamer original SHA256 differs: " + name)
        require(
            record["files"][name]
            == {"sha256": expected, "bytes": len(data), "kind": role},
            "GStreamer original record differs: " + name,
        )
        payloads[name] = data
    contexts = _gst["CONTEXT_PATHS"][kind]
    require(
        isinstance(record.get("working_context_sha256"), dict),
        "GStreamer working context paths differ",
    )
    working = {
        name: original_bytes(root / "working-context" / name) for name in contexts
    }
    require(
        {name: sha(data) for name, data in working.items()}
        == record["working_context_sha256"],
        "GStreamer working context SHA256 differs",
    )
    if kind == "rust":
        require(
            _gst["rust_package"](working, profile) == record.get("gtk4_package"),
            "GStreamer working GTK4 record differs",
        )
    payloads.update(("working-context/" + name, data) for name, data in working.items())
    payloads["source.patch"] = original_bytes(
        root / "source.patch", max_bytes=8 * 1024 * 1024, allow_empty=True
    )
    require(
        sha(payloads["source.patch"]) == record.get("source_patch_sha256"),
        "GStreamer source patch SHA256 differs",
    )
    payloads["source-record.json"] = original_bytes(root / "source-record.json")
    exact_tree(root, set(payloads))
    return payloads


def gstreamer_originals(prefix: Path, version: str, policy: Path) -> dict[str, bytes]:
    root = prefix / "share/licenses/gstreamer-source-build"
    plain_parents(root / ".tree-root")
    children = {path.name for path in root.iterdir()}
    rust = children & {"rust-monorepo", "rust-standalone"}
    require(
        len(rust) == 1 and children == {"monorepo"} | rust,
        "GStreamer requires monorepo and one selected Rust source",
    )
    result = {}
    for directory in sorted(children):
        kind = "monorepo" if directory == "monorepo" else "rust"
        selected = root / directory
        profile, record = gst_record(selected, policy, version, kind)
        payloads = gst_payloads(selected, profile, record, kind)
        result.update(
            ("gstreamer-source-build/" + directory + "/" + name, data)
            for name, data in payloads.items()
        )
    return result


def stage(args: argparse.Namespace) -> dict[str, Any]:
    destination = args.destination.absolute()
    payloads = {}
    for prefix, version, label in (
        (args.gcc_prefix, args.gcc_version, "GCC"),
        (args.gstreamer_prefix, args.gstreamer_version, "GStreamer"),
    ):
        require(
            (prefix is None) == (version is None),
            label + " prefix and version must be supplied together",
        )
        if prefix is not None:
            require(
                not destination.is_relative_to(prefix.absolute()),
                "Destination must be outside selected image prefix",
            )
    require(
        args.gcc_prefix is not None or args.gstreamer_prefix is not None,
        "Select at least one source-original component",
    )
    if args.gcc_prefix is not None:
        payloads.update(
            gcc_originals(
                args.gcc_prefix.absolute(), args.gcc_version, args.gcc_policy.absolute()
            )
        )
    if args.gstreamer_prefix is not None:
        payloads.update(
            gstreamer_originals(
                args.gstreamer_prefix.absolute(),
                args.gstreamer_version,
                args.gstreamer_policy.absolute(),
            )
        )
    record = {
        "schema": 1,
        "status": "selected-image-source-originals-preserved",
        "files": {
            name: {"sha256": sha(data), "bytes": len(data)}
            for name, data in sorted(payloads.items())
        },
        "binary_linkage_or_complete_license_source_closure_proven": False,
    }
    payloads["source-originals.json"] = (json.dumps(record, indent=2) + "\n").encode()
    write_originals(destination, payloads)
    return record


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("--gcc-prefix", type=Path)
    parser.add_argument("--gcc-version")
    parser.add_argument("--gstreamer-prefix", type=Path)
    parser.add_argument("--gstreamer-version")
    parser.add_argument(
        "--gcc-policy",
        type=Path,
        default=Path(__file__).with_name("gcc-runtime-originals.json"),
    )
    parser.add_argument(
        "--gstreamer-policy",
        type=Path,
        default=GSTREAMER_CONTRACT.with_name("original-notices.json"),
    )
    args = parser.parse_args()
    try:
        record = stage(args)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, "Image source original staging refused: " + str(error) + "\n")
    print(json.dumps({"status": record["status"], "files": len(record["files"])}))


if __name__ == "__main__":
    main()
