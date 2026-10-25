#!/usr/bin/env python3
"""Pin one initialized consumer submodule to an explicit remote ANTfrastructure develop SHA."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

SUBMODULE = "third_party/ANTfrastructure"


class PinError(Exception):
    """A precondition failed before the consumer gitlink could be staged."""


def git(root: Path, *args: str) -> str:
    proc = subprocess.run(
        ["git", "-C", str(root), *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode:
        raise PinError(f"git {' '.join(args[:2])} failed in {root} (exit {proc.returncode})")
    return proc.stdout.strip()


def pin(repo: Path, branch: str, sha: str) -> None:
    repo = repo.resolve()
    if not re.fullmatch(r"[0-9a-fA-F]{40}", sha):
        raise PinError("--sha must be a full 40-character commit ID")
    sha = sha.lower()
    if not repo.is_dir() or Path(git(repo, "rev-parse", "--show-toplevel")).resolve() != repo:
        raise PinError("--repo must be the root of a consumer Git checkout")
    if git(repo, "symbolic-ref", "--quiet", "--short", "HEAD") != branch:
        raise PinError(f"consumer checkout must be on --branch {branch}")
    if git(repo, "ls-files", "--unmerged", "--", SUBMODULE):
        raise PinError("the ANTfrastructure gitlink has an unresolved merge conflict")
    record = git(repo, "ls-files", "--stage", "--", SUBMODULE)
    if not re.fullmatch(rf"160000 [0-9a-f]{{40}} 0\t{SUBMODULE}", record):
        raise PinError(f"{SUBMODULE} must be a staged or committed submodule gitlink")
    remote = git(repo, "ls-remote", "--exit-code", "origin", f"refs/heads/{branch}")
    if remote.split()[0] != git(repo, "rev-parse", "HEAD"):
        raise PinError(f"consumer checkout is not at origin/{branch}; pull before pinning")

    sub = repo / SUBMODULE
    if not sub.is_dir() or Path(git(sub, "rev-parse", "--show-toplevel")).resolve() != sub:
        raise PinError(f"{SUBMODULE} is not initialized; run git submodule update --init")
    if git(sub, "status", "--porcelain", "--untracked-files=normal"):
        raise PinError(f"{SUBMODULE} has local changes; finish them before pinning")
    git(sub, "fetch", "--quiet", "--no-tags", "origin", "develop")
    if git(sub, "rev-parse", "FETCH_HEAD") != sha:
        raise PinError("--sha is not the current origin/develop tip of ANTfrastructure")

    git(sub, "checkout", "--quiet", "--detach", sha)
    git(repo, "add", "--", SUBMODULE)
    staged = git(repo, "ls-files", "--stage", "--", SUBMODULE)
    if staged != f"160000 {sha} 0\t{SUBMODULE}":
        raise PinError("the staged ANTfrastructure gitlink does not match --sha")
    print(f"PINNED {repo.name}: {SUBMODULE} -> {sha} (staged; no commit or push)")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo", type=Path, required=True, help="consumer Git checkout root")
    ap.add_argument("--branch", required=True, help="current consumer branch, such as develop or main")
    ap.add_argument("--sha", required=True, help="full ANTfrastructure origin/develop commit ID")
    args = ap.parse_args()
    try:
        pin(args.repo, args.branch, args.sha)
    except (PinError, OSError, IndexError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
