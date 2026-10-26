#!/usr/bin/env python3
"""Hash every build-context file the runtime Dockerfiles can read: docs/linux-cross-builds.md#a-failed-arch-re-runs-alone."""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import shlex
import sys
from pathlib import Path

# .dockerignore keeps these out of the context, so they cannot change what a build reads.
_SKIP_DIRS = frozenset({"__pycache__"})
_SKIP_SUFFIXES = (".pyc",)
_CONTEXT_INSTRUCTIONS = frozenset({"COPY", "ADD"})


class ClosureError(Exception):
    """A context input this helper cannot pin down; the caller must not reuse anything."""


def _logical_lines(text: str) -> list[str]:
    lines: list[str] = []
    current = ""
    for raw in text.splitlines():
        stripped = raw.strip()
        # Docker drops comment lines, inside a continuation too.
        if not stripped or stripped.startswith("#"):
            continue
        if raw.rstrip().endswith("\\"):
            current += raw.rstrip()[:-1] + " "
            continue
        lines.append(current + raw)
        current = ""
    if current:
        lines.append(current)
    return lines


def _mount_sources(line: str) -> list[str]:
    sources: list[str] = []
    for match in re.finditer(r"--mount=(\S+)", line):
        fields = {key: value for key, _, value in (part.partition("=") for part in match.group(1).split(","))}
        if fields.get("type", "bind") != "bind" or "from" in fields:
            continue
        # A bind without source= mounts the whole context, which no file list can bound.
        if not fields.get("source"):
            raise ClosureError(f"context bind without source=: {match.group(0)}")
        sources.append(fields["source"])
    return sources


def _copy_sources(line: str) -> list[str]:
    words = line.split(None, 1)
    if len(words) < 2 or words[0].upper() not in _CONTEXT_INSTRUCTIONS:
        return []
    rest = words[1].strip()
    if rest.startswith("[") or "<<" in rest:
        raise ClosureError(f"unsupported {words[0]} form: {line.strip()}")
    words = shlex.split(rest)
    if any(word.startswith("--from=") for word in words):
        return []
    tokens = [word for word in words if not word.startswith("--")]
    if len(tokens) < 2:
        raise ClosureError(f"{words[0]} without a source: {line.strip()}")
    return tokens[:-1]


def context_sources(dockerfile: Path) -> list[str]:
    """Return the context paths one Dockerfile binds or copies."""
    found: list[str] = []
    for line in _logical_lines(dockerfile.read_text(encoding="utf-8")):
        found.extend(_mount_sources(line))
        found.extend(_copy_sources(line))
    return found


def _resolve(root: Path, source: str) -> Path:
    if any(char in source for char in "$*?["):
        raise ClosureError(f"source is not a literal path: {source}")
    path = (root / source.lstrip("/")).resolve()
    if root.resolve() not in (path, *path.parents):
        raise ClosureError(f"source leaves the context: {source}")
    if not path.exists() and not path.is_symlink():
        raise ClosureError(f"source does not exist: {source}")
    return path


def _files_under(path: Path) -> list[Path]:
    if not path.is_dir() or path.is_symlink():
        return [path]
    found: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(path):
        dirnames[:] = sorted(name for name in dirnames if name not in _SKIP_DIRS)
        found.extend(Path(dirpath) / name for name in filenames if not name.endswith(_SKIP_SUFFIXES))
    return found


def _file_record(root: Path, path: Path) -> str:
    rel = path.relative_to(root.resolve()).as_posix()
    if path.is_symlink():
        return f"link {rel} {os.readlink(path)}"
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    mode = "x" if os.access(path, os.X_OK) else "-"
    return f"file {rel} {mode} {digest}"


def closure_records(root: Path, dockerfiles: list[str], extras: list[str]) -> list[str]:
    """Return one sorted record per file that the given Dockerfiles can read."""
    paths: set[Path] = set()
    for name in [*dockerfiles, *extras]:
        paths.add(_resolve(root, name))
    for name in dockerfiles:
        for source in context_sources(root / name):
            paths.update(_files_under(_resolve(root, source)))
    files: set[Path] = set()
    for path in paths:
        files.update(_files_under(path))
    return sorted(_file_record(root, path) for path in files)


def main(argv: list[str]) -> int:
    """Print the closure hash, or the records with --list."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--dockerfile", action="append", required=True)
    parser.add_argument("--extra", action="append", default=[])
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args(argv)
    try:
        records = closure_records(Path(args.root), args.dockerfile, args.extra)
    except (ClosureError, OSError, UnicodeDecodeError) as exc:
        print(f"runtime-build-key: {exc}", file=sys.stderr)
        return 1
    if args.list:
        print("\n".join(records))
        return 0
    print(hashlib.sha256("\n".join(records).encode()).hexdigest())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
