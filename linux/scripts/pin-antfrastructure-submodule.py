#!/usr/bin/env python3
"""Pin one initialized direct submodule to an explicit remote default-branch SHA."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath

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
        raise PinError(
            f"git {' '.join(args[:2])} failed in {root} (exit {proc.returncode})"
        )
    return proc.stdout.strip()


def direct_submodule(repo: Path, path: str) -> Path:
    relative = PurePosixPath(path)
    if (
        not path
        or "\\" in path
        or relative.is_absolute()
        or relative.as_posix() != path
        or any(part in (".", "..") for part in path.split("/"))
        or ":" in relative.parts[0]
    ):
        raise PinError("--path must be a normalized relative submodule path")
    if not re.fullmatch(
        r"100(?:644|755) [0-9a-f]{40} 0\t\.gitmodules",
        git(repo, "ls-files", "--stage", "--", ".gitmodules"),
    ):
        raise PinError("the consumer must track .gitmodules")
    declarations = git(
        repo,
        "config",
        "-z",
        "-f",
        ".gitmodules",
        "--get-regexp",
        r"^submodule\..*\.path$",
    )
    declared_paths = [
        entry.partition("\n")[2] for entry in declarations.split("\0") if entry
    ]
    if declared_paths.count(path) != 1:
        raise PinError(f"{path} must appear exactly once as a direct .gitmodules path")
    if git(repo, "ls-files", "--unmerged", "--", path):
        raise PinError(f"{path} has an unresolved gitlink merge conflict")
    record = git(repo, "ls-files", "--stage", "--", path)
    if not re.fullmatch(rf"160000 [0-9a-f]{{40}} 0\t{re.escape(path)}", record):
        raise PinError(f"{path} must be a staged or committed submodule gitlink")
    sub = repo / path
    if (
        sub.resolve() != sub
        or not sub.is_dir()
        or Path(git(sub, "rev-parse", "--show-toplevel")).resolve() != sub
    ):
        raise PinError(f"{path} is not initialized; run git submodule update --init")
    return sub


def remote_default_ref(sub: Path) -> str:
    remote_head = git(sub, "ls-remote", "--symref", "--exit-code", "origin", "HEAD")
    match = re.fullmatch(
        r"ref: (refs/heads/[^\t\n]+)\tHEAD\n[0-9a-fA-F]{40}\tHEAD", remote_head
    )
    if match is None:
        raise PinError(f"{sub} origin has no usable default branch")
    return match.group(1)


def pin(repo: Path, branch: str, sha: str, path: str = SUBMODULE) -> None:
    repo = repo.resolve()
    if not re.fullmatch(r"[0-9a-fA-F]{40}", sha):
        raise PinError("--sha must be a full 40-character commit ID")
    sha = sha.lower()
    if (
        not repo.is_dir()
        or Path(git(repo, "rev-parse", "--show-toplevel")).resolve() != repo
    ):
        raise PinError("--repo must be the root of a consumer Git checkout")
    if git(repo, "symbolic-ref", "--quiet", "--short", "HEAD") != branch:
        raise PinError(f"consumer checkout must be on --branch {branch}")
    sub = direct_submodule(repo, path)
    remote = git(repo, "ls-remote", "--exit-code", "origin", f"refs/heads/{branch}")
    if remote.split()[0] != git(repo, "rev-parse", "HEAD"):
        raise PinError(
            f"consumer checkout is not at origin/{branch}; pull before pinning"
        )

    if git(sub, "status", "--porcelain", "--untracked-files=normal"):
        raise PinError(f"{path} has local changes; finish them before pinning")
    default_ref = remote_default_ref(sub)
    git(sub, "fetch", "--quiet", "--no-tags", "origin", default_ref)
    if git(sub, "rev-parse", "FETCH_HEAD") != sha:
        raise PinError(f"--sha is not the current origin default-branch tip for {path}")

    git(sub, "checkout", "--quiet", "--detach", sha)
    git(repo, "add", "--", path)
    staged = git(repo, "ls-files", "--stage", "--", path)
    if staged != f"160000 {sha} 0\t{path}":
        raise PinError(f"the staged {path} gitlink does not match --sha")
    print(f"PINNED {repo.name}: {path} -> {sha} (staged; no commit or push)")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--repo", type=Path, required=True, help="consumer Git checkout root"
    )
    ap.add_argument(
        "--branch",
        required=True,
        help="current consumer branch, such as develop or main",
    )
    ap.add_argument("--sha", required=True, help="full remote default-branch commit ID")
    ap.add_argument(
        "--path",
        default=SUBMODULE,
        help=f"direct submodule path (default: {SUBMODULE})",
    )
    args = ap.parse_args()
    try:
        pin(args.repo, args.branch, args.sha, args.path)
    except (PinError, OSError, IndexError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
