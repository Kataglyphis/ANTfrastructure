#!/usr/bin/env python3
"""Validate a caller's tracked mutation recipes before starting a costly proof."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from verify_mutations import load, select_shard


def die(message: str) -> int:
    print(f"ERROR: {message}", file=sys.stderr)
    return 2


def git_root(root: Path) -> bool:
    proc = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=False,
    )
    return proc.returncode == 0 and Path(proc.stdout.strip()).resolve() == root


def tracked_file(root: Path, name: str, label: str) -> Path:
    path = Path(name)
    if path.is_absolute() or not name:
        raise ValueError(f"{label} needs a caller-relative file path")
    resolved = (root / path).resolve()
    if not resolved.is_relative_to(root) or not resolved.is_file():
        raise ValueError(f"{label} must be a file within the caller checkout")
    rel = resolved.relative_to(root).as_posix()
    proc = subprocess.run(
        [
            "git",
            "-C",
            str(root),
            "--literal-pathspecs",
            "ls-files",
            "--error-unmatch",
            "--",
            rel,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise ValueError(f"{label} must be tracked by the caller")
    return resolved


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", required=True, help="caller Git checkout root")
    ap.add_argument(
        "--manifest", required=True, help="tracked caller-relative recipe list"
    )
    ap.add_argument(
        "--setup-script", default="", help="optional tracked caller-relative setup"
    )
    ap.add_argument("--shard", default="", help="optional nonempty K/N recipe shard")
    args = ap.parse_args()
    root = Path(args.root).resolve()
    if not root.is_dir() or not git_root(root):
        return die("--root must name the top of a Git checkout")
    try:
        manifest = tracked_file(root, args.manifest, "mutation manifest")
        if args.setup_script:
            tracked_file(root, args.setup_script, "mutation setup script")
        recipes = load(str(manifest))
        selected = select_shard(recipes, args.shard or None)
    except (OSError, ValueError, TypeError, KeyError) as exc:
        return die(f"invalid mutation manifest or setup: {exc}")
    if not selected:
        return die("mutation manifest or shard selects no recipe")
    print(f"OK: {len(selected)} mutation recipe(s) selected from {manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
