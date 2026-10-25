#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""Print the digest of one platform's manifest inside a public multi-arch image index.

Usage: registry-platform-digest.py <repo>@<digest>|<repo>:<tag> <os/arch>; see docs/riscv64-cross-test-lanes.md#the-building-blocks-measured-2026-10-01
"""
from __future__ import annotations

import json
import sys
import urllib.parse
import urllib.request

INDEX_TYPES = (
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
)


def split_ref(ref: str) -> tuple[str, str, str]:
    """(registry, repository, tag-or-digest) of a fully qualified reference."""
    host, _, rest = ref.partition("/")
    if not rest or "." not in host:
        raise ValueError(f"not a fully qualified reference: {ref}")
    if "@" in rest:
        repo, _, ident = rest.partition("@")
    else:
        repo, _, ident = rest.rpartition(":")
        if not repo or "/" in ident:
            raise ValueError(f"reference has no tag or digest: {ref}")
    return host, repo, ident


def select_platform(index: dict, platform: str) -> str:
    """The digest of the manifest for `os/arch` in an image index; attestation entries never match."""
    want_os, _, want_arch = platform.partition("/")
    hits = [
        m["digest"]
        for m in index.get("manifests", [])
        if m.get("platform", {}).get("os") == want_os
        and m.get("platform", {}).get("architecture") == want_arch
    ]
    if len(hits) != 1:
        raise LookupError(f"{len(hits)} manifests for {platform} in the index, expected exactly 1")
    return hits[0]


def _token(host: str, repo: str) -> str:
    query = urllib.parse.urlencode({"scope": f"repository:{repo}:pull"})
    with urllib.request.urlopen(f"https://{host}/token?{query}", timeout=60) as resp:
        return json.load(resp)["token"]


def fetch_index(host: str, repo: str, ident: str) -> dict:
    req = urllib.request.Request(
        f"https://{host}/v2/{repo}/manifests/{ident}",
        headers={"Accept": ", ".join(INDEX_TYPES), "Authorization": "Bearer " + _token(host, repo)},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
        return 2
    try:
        host, repo, ident = split_ref(argv[1])
        print(select_platform(fetch_index(host, repo, ident), argv[2]))
    except (ValueError, LookupError, OSError, KeyError) as exc:
        sys.stderr.write(f"registry-platform-digest.py: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
