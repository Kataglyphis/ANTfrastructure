#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Read GHCR package metadata without contacting the registry."""
import json
import sys


def version_tags(version):
    return version.get("metadata", {}).get("container", {}).get("tags", [])


def main():
    payload = json.load(sys.stdin)
    mode = sys.argv[1]
    if mode == "inventory":
        for version in payload:
            tags = ",".join(version_tags(version))
            print("%s\t%s\t%s\t%s" % (version["id"], version["name"], version["created_at"], tags))
    elif mode == "tag-count":
        print(len(version_tags(payload)))
    else:
        raise SystemExit("unknown GHCR metadata mode: " + mode)


if __name__ == "__main__":
    main()
