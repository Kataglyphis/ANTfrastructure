"""Own disposable mutation mirrors; path checks do not authenticate concurrent writers or prove cache hits."""

from __future__ import annotations

import ntpath
import os
import shutil
import tempfile
from collections.abc import Callable, Generator
from contextlib import contextmanager
from pathlib import Path


def validate_workspace_root(source: str, requested: str) -> Path:
    """An explicit workspace must be a literal absolute path outside the source tree."""
    root = Path(requested)
    if not root.is_absolute() or os.path.abspath(requested) != requested:
        raise ValueError("--workspace-root must be an absolute normalized path")
    if root.parent.resolve(strict=True) != root.parent:
        raise ValueError("--workspace-root parent must not contain symlinks")
    source_path = Path(source).resolve(strict=True)
    if root.is_relative_to(source_path) or source_path.is_relative_to(root):
        raise ValueError("--workspace-root must not overlap the source tree")
    return root


@contextmanager
def mutation_workspaces(source: str, requested: str | None) -> Generator[Callable[[], str], None, None]:
    """Own fresh mirrors; fixed private roots aid Rust cache keys without sharing writable workspaces."""
    roots: list[str] = []
    explicit = validate_workspace_root(source, requested) if requested is not None else None
    identity: tuple[int, int] | None = None
    if explicit is not None:
        explicit.mkdir(mode=0o700)
        info = explicit.lstat()
        identity = (info.st_dev, info.st_ino)

    def allocate() -> str:
        if explicit is None:
            root = tempfile.mkdtemp(prefix="mutation-gate-")
        else:
            path = explicit / f"worker-{len(roots)}"
            path.mkdir(mode=0o700)
            root = str(path)
        roots.append(root)
        return root

    try:
        yield allocate
    finally:
        if explicit is None:
            for root in roots:
                shutil.rmtree(root, ignore_errors=True)
        else:
            current = explicit.lstat()
            if (current.st_dev, current.st_ino) != identity or explicit.parent.resolve(strict=True) != explicit.parent:
                raise ValueError("Explicit mutation workspace identity changed; refusing cleanup")
            shutil.rmtree(explicit)


def relative_file_path(path: str, label: str) -> str:
    """Require a portable relative file name without components that could leave a mirror."""
    if (not isinstance(path, str) or not path or "\\" in path
            or ntpath.splitdrive(path)[0]
            or any(part in ("", ".", "..") for part in path.split("/"))):
        raise ValueError(f"{label} must be a normalized relative path inside the mutation root")
    return path


def drop_bytecode(path: str) -> None:
    """Python trusts a cached .pyc whose source size and mtime second match, so a same-size mutant can run stale code."""
    stem, ext = os.path.splitext(os.path.basename(path))
    if ext != ".py":
        return
    cache = os.path.join(os.path.dirname(path), "__pycache__")
    for name in os.listdir(cache) if os.path.isdir(cache) else ():
        if name.startswith(stem + ".") and name.endswith(".pyc"):
            os.unlink(os.path.join(cache, name))
