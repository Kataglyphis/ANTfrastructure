#!/usr/bin/env python3
"""Read and update the JSON metadata used by the Renovate CLI bootstrap."""

from __future__ import annotations

import json
import re
import sys
from collections.abc import Callable
from pathlib import Path
from typing import Any

VERSION = re.compile(
    r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*)?"
    r"(?:\+[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*)?"
)
NODE_VERSION = re.compile(r"v?([0-9]+)\.([0-9]+)\.([0-9]+)")


def read_json(path: str) -> dict[str, Any]:
    with Path(path).open(encoding="utf-8") as source:
        return json.load(source)


def latest(_args: list[str]) -> int:
    value = json.load(sys.stdin)
    if not isinstance(value, str) or len(value) > 128 or not VERSION.fullmatch(value):
        return 1
    print(value)
    return 0


def node_version(args: list[str]) -> int:
    actual = NODE_VERSION.fullmatch(args[1])
    pinned = NODE_VERSION.fullmatch(args[2])
    if args[0] not in {"exact", "at-least"} or actual is None or pinned is None:
        return 1
    found = tuple(int(part) for part in actual.groups())
    required = tuple(int(part) for part in pinned.groups())
    if found[0] != required[0]:
        return 1
    return 0 if (found == required if args[0] == "exact" else found >= required) else 1


def lock_version(args: list[str]) -> int:
    print(read_json(args[0])["packages"]["node_modules/renovate"]["version"])
    return 0


def manifest_version(args: list[str]) -> int:
    print(read_json(args[0])["dependencies"]["renovate"])
    return 0


def stage_manifest(args: list[str]) -> int:
    manifest = read_json(args[0])
    manifest["dependencies"]["renovate"] = args[2]
    Path(args[1]).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return 0


def verify_lock(args: list[str]) -> int:
    package = read_json(args[0])["packages"]["node_modules/renovate"]
    return 0 if package.get("version") == args[1] and package.get("integrity") else 1


def installed_version(args: list[str]) -> int:
    print(read_json(args[0])["version"])
    return 0


def main(argv: list[str]) -> int:
    commands: dict[str, tuple[int, Callable[[list[str]], int]]] = {
        "latest": (0, latest),
        "node-version": (3, node_version),
        "lock-version": (1, lock_version),
        "manifest-version": (1, manifest_version),
        "stage-manifest": (3, stage_manifest),
        "verify-lock": (2, verify_lock),
        "installed-version": (1, installed_version),
    }
    selected = commands.get(argv[1]) if len(argv) > 1 else None
    if selected is None or len(argv) != selected[0] + 2:
        return 1
    try:
        return selected[1](argv[2:])
    except (OSError, ValueError, KeyError, TypeError, IndexError):
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
