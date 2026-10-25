#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Read GHCR package metadata without contacting the registry."""
import json
import sys
from typing import TypedDict


class ContainerMetadata(TypedDict, total=False):
    tags: list[str]


class PackageMetadata(TypedDict, total=False):
    container: ContainerMetadata


class PackageVersion(TypedDict, total=False):
    metadata: PackageMetadata


def version_tags(version: PackageVersion) -> list[str]:
    return version.get("metadata", {}).get("container", {}).get("tags", [])


def main() -> None:
    payload = json.load(sys.stdin)
    mode = sys.argv[1]
    if mode == "inventory":
        for version in payload:
            tags = ",".join(version_tags(version))
            print(f"{version['id']}\t{version['name']}\t{version['created_at']}\t{tags}")
    elif mode == "tag-count":
        print(len(version_tags(payload)))
    else:
        raise SystemExit("unknown GHCR metadata mode: " + mode)


if __name__ == "__main__":
    main()
