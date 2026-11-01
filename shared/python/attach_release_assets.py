#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
"""Attach new files to an existing release only when its tag is the expected commit."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote

REPO = re.compile(r"[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+\Z")
TAG = re.compile(r"v[0-9][A-Za-z0-9.+-]*\Z")
SHA = re.compile(r"[0-9a-f]{40}\Z")
ASSET = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]*\Z")


def api(path: str) -> dict:
    """Read one GitHub API object using the caller's authenticated gh CLI."""
    result = subprocess.run(
        ["gh", "api", path], check=True, capture_output=True, text=True
    )
    data = json.loads(result.stdout)
    if not isinstance(data, dict):
        raise TypeError("GitHub returned an unexpected response")
    return data


def tag_commit(repo: str, tag: str) -> str:
    """Resolve lightweight and annotated tags without trusting target_commitish."""
    obj = api(f"repos/{repo}/git/ref/tags/{quote(tag, safe='')}")["object"]
    for _ in range(8):
        kind, sha = obj["type"], obj["sha"]
        if not isinstance(sha, str) or not SHA.fullmatch(sha):
            raise ValueError("invalid Git tag object")
        if kind == "commit":
            return sha
        if kind != "tag":
            raise ValueError("release tag does not point to a commit")
        obj = api(f"repos/{repo}/git/tags/{sha}")["object"]
    raise ValueError("too many nested annotated tags")


def release_assets(repo: str, release_id: int) -> list[dict]:
    """Read every asset page before checking for existing names."""
    result = subprocess.run(
        [
            "gh",
            "api",
            "--paginate",
            "--slurp",
            f"repos/{repo}/releases/{release_id}/assets",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    pages = json.loads(result.stdout)
    if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
        raise ValueError("invalid release asset pages")
    return [item for page in pages for item in page]


def assets(directory: Path) -> list[Path]:
    """Require a flat, nonempty collection of ordinary, nonempty files."""
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("asset directory is missing or linked")
    files = sorted(directory.iterdir())
    if not files or any(
        not ASSET.fullmatch(p.name)
        or p.is_symlink()
        or not p.is_file()
        or p.stat().st_size == 0
        for p in files
    ):
        raise ValueError("assets must be nonempty regular files in a flat directory")
    if len({p.name.casefold() for p in files}) != len(files):
        raise ValueError("asset names collide")
    return files


def attach(
    repo: str,
    tag: str,
    revision: str,
    directory: Path | None,
    dry_run: bool,
    check_only: bool = False,
    expected_names: tuple[str, ...] = (),
) -> None:
    """Fail on the wrong tag or a name collision; never replace release assets."""
    if (
        not REPO.fullmatch(repo)
        or not TAG.fullmatch(tag)
        or not SHA.fullmatch(revision)
    ):
        raise ValueError("invalid repository, release tag or commit")
    if check_only and directory is not None:
        raise ValueError("check-only does not accept an asset directory")
    if not check_only and directory is None:
        raise ValueError("an asset directory is required")
    if expected_names and not check_only:
        raise ValueError("expected names are only accepted for check-only")
    if any(not ASSET.fullmatch(name) for name in expected_names) or len(
        {name.casefold() for name in expected_names}
    ) != len(expected_names):
        raise ValueError("invalid or duplicate expected asset names")
    files = [] if directory is None else assets(directory)
    if dry_run:
        for path in files:
            print(path.name)
        return
    release = api(f"repos/{repo}/releases/tags/{quote(tag, safe='')}")
    if release.get("tag_name") != tag or release.get("draft") is not False:
        raise ValueError(
            "expected an existing published release with the requested tag"
        )
    if tag_commit(repo, tag) != revision:
        raise ValueError("release tag does not point to the workflow commit")
    if check_only and not expected_names:
        return
    release_id = release.get("id")
    if type(release_id) is not int or release_id <= 0:
        raise ValueError("release has no valid ID")
    existing = release_assets(repo, release_id)
    if any(
        not isinstance(x, dict) or not isinstance(x.get("name"), str) for x in existing
    ):
        raise ValueError("release asset list is invalid")
    occupied = {x["name"].casefold() for x in existing}
    wanted = expected_names if check_only else (p.name for p in files)
    if occupied.intersection(name.casefold() for name in wanted):
        raise ValueError("release already has an asset with one of these names")
    if check_only:
        return
    subprocess.run(
        ["gh", "release", "upload", tag, "--repo", repo, *(str(p) for p in files)],
        check=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("repo", "tag", "revision"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--assets")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--check-only", action="store_true")
    parser.add_argument("--expected-name", action="append", default=[])
    args = parser.parse_args()
    try:
        attach(
            args.repo,
            args.tag,
            args.revision,
            Path(args.assets) if args.assets else None,
            args.dry_run,
            args.check_only,
            tuple(args.expected_name),
        )
    except (
        OSError,
        KeyError,
        TypeError,
        ValueError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"Release assets: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
