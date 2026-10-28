#!/usr/bin/env python3
"""Fail when a submodule at any depth vendors the root repository again, which makes every recursive clone loop."""

import argparse
import configparser
import re
import subprocess
import sys
from pathlib import Path


def repo_key(url: str) -> str:
    """owner/name of a GitHub-style URL, lowercased; https, ssh and .git spellings compare equal."""
    match = re.search(r"[:/]([^/:]+)/([^/]+?)(?:\.git)?/*$", url.strip())
    return (
        f"{match.group(1)}/{match.group(2)}".lower() if match else url.strip().lower()
    )


def declared(checkout: Path) -> list[tuple[str, str]]:
    """(path, url) of every entry in checkout/.gitmodules."""
    gitmodules = checkout / ".gitmodules"
    if not gitmodules.is_file():
        return []
    parser = configparser.ConfigParser(interpolation=None)
    parser.read_string(gitmodules.read_text(encoding="utf-8"))
    entries = []
    for section in parser.sections():
        if not section.startswith("submodule "):
            continue
        if "path" not in parser[section] or "url" not in parser[section]:
            raise ValueError(f"{gitmodules}: [{section}] lacks path or url")
        entries.append((parser[section]["path"], parser[section]["url"]))
    return entries


def origin_key(root: Path) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), "remote", "get-url", "origin"],
        capture_output=True,
        text=True,
        check=True,
    )
    return repo_key(result.stdout)


def walk(root: Path, forbidden: str) -> tuple[list[str], list[str]]:
    """(cycles, unchecked): nested entries naming the root, and declared entries with no checkout to read."""
    cycles, unchecked = [], []
    pending = [(root, "")]
    while pending:
        checkout, prefix = pending.pop()
        for path, url in declared(checkout):
            shown = f"{prefix}{path}"
            if repo_key(url) == forbidden:
                cycles.append(f"{shown} -> {url}")
                continue
            child = checkout / path
            if not (child / ".git").exists():
                unchecked.append(shown)
                continue
            pending.append((child, f"{shown}/"))
    return cycles, unchecked


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path.cwd(),
        help="checkout whose origin no submodule may vendor",
    )
    parser.add_argument(
        "--forbid", help="owner/name to refuse instead of the root's origin"
    )
    args = parser.parse_args()
    try:
        forbidden = repo_key(args.forbid) if args.forbid else origin_key(args.root)
        cycles, unchecked = walk(args.root, forbidden)
    except (
        OSError,
        ValueError,
        configparser.Error,
        subprocess.CalledProcessError,
    ) as error:
        print(
            f"submodule cycles: cannot read the submodule graph: {error}",
            file=sys.stderr,
        )
        return 2
    for cycle in cycles:
        print(
            f"submodule cycles: {cycle} vendors {forbidden} again; call its workflows with hub-checkout: true",
            file=sys.stderr,
        )
    for path in unchecked:
        print(
            f"submodule cycles: {path} is not checked out, so its own submodules went unread",
            file=sys.stderr,
        )
    if cycles or unchecked:
        return 1
    print(f"submodule cycles: no submodule below {args.root} vendors {forbidden}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
