#!/usr/bin/env python3
"""Preserve committed consumer trees or explicitly selected working overlays; no build, source authentication or inference proof."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import stat
import subprocess
from pathlib import Path
from typing import Any

from source_ci.common import fingerprint, read, require, save, timestamp


def git(root: Path, *arguments: str) -> bytes:
    return subprocess.run(
        ["git", "-C", str(root), *arguments],
        capture_output=True,
        check=True,
        timeout=300,
    ).stdout


def head(root: Path) -> str:
    require(
        git(root, "rev-parse", "--show-toplevel").decode().strip() == str(root),
        "Consumer Git root differs",
    )
    value = git(root, "rev-parse", "HEAD").decode().strip()
    require(
        re.fullmatch(r"[0-9a-f]{40}", value) is not None, "Consumer commit is malformed"
    )
    return value


def links(root: Path) -> list[tuple[str, str]]:
    result = []
    for row in git(root, "ls-tree", "-rz", "--full-tree", "HEAD").split(b"\0"):
        if not row:
            continue
        metadata, name = row.split(b"\t", 1)
        mode, _kind, revision = metadata.decode().split()
        if mode == "160000":
            path = name.decode()
            require(
                not Path(path).is_absolute() and ".." not in Path(path).parts,
                "Consumer gitlink escapes its tree",
            )
            result.append((path, revision))
    return result


def verify_objects(root: Path) -> None:
    objects = Path(git(root, "rev-parse", "--git-path", "objects").decode().strip())
    if not objects.is_absolute():
        objects = root / objects
    objects = objects.resolve(strict=True)
    require(
        objects.is_relative_to(root)
        and not (objects / "info/alternates").exists()
        and not list((objects / "pack").glob("*.promisor")),
        "Preserved objects still borrow or promise bytes",
    )
    git(root, "fsck", "--full", "--strict", "--no-reflogs")


def verify_tree(root: Path, revision: str, index_sha256: str | None = None) -> str:
    require(head(root) == revision, "Preserved consumer Git root changed")
    verify_objects(root)
    digest = hashlib.sha256(git(root, "ls-files", "--stage", "-z")).hexdigest()
    require(
        index_sha256 is None or digest == index_sha256,
        "Preserved consumer index changed",
    )
    require(
        not git(
            root,
            "status",
            "--porcelain",
            "--untracked-files=no",
            "--ignore-submodules=none",
        ).strip(),
        "Preserved consumer tree is dirty",
    )
    return digest


def clone_checkout(source: Path, destination: Path, revision: str) -> None:
    require(
        not destination.exists() or not any(destination.iterdir()),
        "Refusing an existing preservation tree",
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "git",
            "clone",
            "--local",
            "--no-hardlinks",
            "--dissociate",
            "--no-checkout",
            "--",
            str(source),
            str(destination),
        ],
        capture_output=True,
        check=True,
        timeout=300,
    )
    git(destination, "checkout", "--detach", revision)


def clone_tree(
    source: Path, destination: Path, expected: str | None = None
) -> list[dict[str, Any]]:
    revision = head(source)
    require(expected is None or revision == expected, "Consumer gitlink commit differs")
    clone_checkout(source, destination, revision)
    require(
        head(destination) == revision and head(source) == revision,
        "Consumer head changed during preservation",
    )
    index = git(destination, "ls-files", "--stage", "-z")
    require(
        index == git(source, "ls-files", "--stage", "-z"),
        "Consumer versioned index differs",
    )
    rows = [
        {
            "source": str(source),
            "preserved": str(destination),
            "head": revision,
            "versioned_index_sha256": hashlib.sha256(index).hexdigest(),
        }
    ]
    children = links(source)
    if children:
        git(destination, "submodule", "init")
    for name, child_revision in children:
        child = (source / name).resolve(strict=True)
        require(
            child.is_relative_to(source),
            "Initialized consumer gitlink escapes its checkout",
        )
        rows.extend(clone_tree(child, destination / name, child_revision))
    verify_tree(destination, revision, hashlib.sha256(index).hexdigest())
    return rows


def working_files(root: Path) -> dict[str, dict[str, str | int]]:
    result: dict[str, dict[str, str | int]] = {}
    for row in git(root, "ls-files", "--stage", "-z").split(b"\0"):
        if not row:
            continue
        metadata, raw_name = row.split(b"\t", 1)
        mode, oid, stage = metadata.decode().split()
        name = raw_name.decode()
        require(stage == "0", "Working source index has unresolved stages")
        require(
            not Path(name).is_absolute() and ".." not in Path(name).parts,
            "Working path escapes its root",
        )
        path = root / name
        if mode == "160000":
            result[name] = {"git_mode": mode, "revision": oid}
        elif mode == "120000":
            require(path.is_symlink(), "Working source link is missing: " + name)
            result[name] = {"git_mode": mode, "link": str(path.readlink())}
        else:
            require(
                mode in {"100644", "100755"}
                and path.is_file()
                and not path.is_symlink(),
                "Working source file is missing: " + name,
            )
            require(
                path.resolve().is_relative_to(root),
                "Working source file escapes its root: " + name,
            )
            result[name] = {
                "git_mode": mode,
                "sha256": fingerprint(path),
                "mode": stat.S_IMODE(path.stat().st_mode),
            }
    return result


def working_snapshot(root: Path) -> tuple[str, bytes, dict[str, dict[str, str | int]]]:
    return head(root), git(root, "ls-files", "--stage", "-z"), working_files(root)


def restore_working_modes(
    destination: Path, files: dict[str, dict[str, str | int]]
) -> None:
    working_files(destination)
    for name, row in files.items():
        if row["git_mode"] in {"100644", "100755"}:
            (destination / name).chmod(int(row["mode"]))


def preserve_working(
    source: Path, destination: Path, directory: Path, revision: str
) -> dict[str, Any]:
    require(
        not destination.is_symlink() and not directory.is_symlink(),
        "Working destination must not be linked",
    )
    source, destination, directory = (
        source.resolve(strict=True),
        destination.resolve(),
        directory.resolve(),
    )
    require(
        re.fullmatch(r"[0-9a-f]{40}", revision) is not None,
        "Working base must be a full commit",
    )
    for output in (destination, directory):
        require(
            not output.is_relative_to(source) and not source.is_relative_to(output),
            "Working destination overlaps its source",
        )
    require(
        not git(source, "diff", "--name-only", "--ignore-submodules=all").strip(),
        "Stage every tracked source edit before preservation",
    )
    original_head, index, files = working_snapshot(source)
    require(bool(files), "Working source has no versioned files")
    patch = git(
        source,
        "diff",
        "--cached",
        "--binary",
        "--full-index",
        revision,
        "--",
        ".",
    )
    directory.mkdir(parents=True, exist_ok=False)
    patch_path = directory / "working.patch"
    patch_path.write_bytes(patch)
    clone_checkout(source, destination, revision)
    if patch:
        git(destination, "apply", "--index", str(patch_path))
    require(head(destination) == revision, "Working base changed during preparation")
    require(
        git(destination, "ls-files", "--stage", "-z") == index,
        "Working source index differs",
    )
    restore_working_modes(destination, files)
    require(
        working_files(destination) == files,
        "Working source bytes, modes or links differ",
    )
    verify_objects(destination)
    require(
        working_snapshot(source) == (original_head, index, files),
        "Working source changed during preparation",
    )
    return {
        "status": "preserved-independent-working-source-only",
        "observed_at": timestamp(),
        "source": str(source),
        "owner_head": original_head,
        "selected_base": revision,
        "destination": str(destination),
        "patch_sha256": hashlib.sha256(patch).hexdigest(),
        "index_sha256": hashlib.sha256(index).hexdigest(),
        "versioned_paths": files,
        "recursive_children_preserved": False,
        "scope": "Exact staged working bytes over an explicitly selected committed base; no pin authentication, recursive children, build or GPU proof.",
    }


def preserve(checkouts: Path, plan: Path, directory: Path) -> dict[str, Any]:
    checkouts, plan = checkouts.resolve(strict=True), plan.resolve(strict=True)
    directory = directory.resolve()
    require(
        not directory.is_relative_to(checkouts)
        and not checkouts.is_relative_to(directory),
        "Preservation overlaps live consumer checkouts",
    )
    directory.mkdir(parents=True, exist_ok=True)
    names = [row["name"] for row in read(plan)["consumers"]]
    require(
        names
        and len(set(names)) == len(names)
        and all(re.fullmatch(r"[A-Za-z0-9_-]+", name) for name in names),
        "Invalid consumer names",
    )
    complete, pending = [], []
    for name in names:
        source, receipt = checkouts / name, directory / (name + ".json")
        if receipt.exists():
            record = read(receipt)
            require(
                record["plan_sha256"] == fingerprint(plan)
                and record["source"] == str(source),
                "Preserved consumer receipt belongs elsewhere",
            )
            require(
                record["roots"]
                and record["roots"][0]["preserved"] == str(directory / name),
                "Preserved consumer roots differ",
            )
            for row in record["roots"]:
                root = Path(row["preserved"]).resolve(strict=True)
                require(
                    root.is_relative_to(directory / name),
                    "Preserved consumer Git root escaped",
                )
                verify_tree(root, row["head"], row["versioned_index_sha256"])
            complete.append(name)
            continue
        if (
            not (source / ".git").exists()
            or not (checkouts / (name + ".log")).is_file()
        ):
            pending.append(name)
            continue
        rows = clone_tree(source.resolve(strict=True), directory / name)
        save(
            receipt,
            {
                "status": "preserved-independent-versioned-consumer-trees-only",
                "observed_at": timestamp(),
                "source": str(source),
                "plan_sha256": fingerprint(plan),
                "roots": rows,
                "scope": __doc__,
            },
        )
        complete.append(name)
    return {
        "status": "preservation-complete" if not pending else "preservation-partial",
        "observed_at": timestamp(),
        "consumers": complete,
        "pending": pending,
        "scope": __doc__,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--checkouts", type=Path)
    mode.add_argument("--working-source", type=Path)
    parser.add_argument("--plan", type=Path)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--revision")
    args = parser.parse_args()
    if args.working_source is not None:
        if args.plan is not None or args.destination is None or args.revision is None:
            parser.error(
                "--working-source needs --destination and --revision, without --plan"
            )
        result = preserve_working(
            args.working_source, args.destination, args.directory, args.revision
        )
    else:
        if (
            args.plan is None
            or args.destination is not None
            or args.revision is not None
        ):
            parser.error("--checkouts needs --plan, without working-source options")
        result = preserve(args.checkouts, args.plan, args.directory)
    save(args.directory / "progress.json", result)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
