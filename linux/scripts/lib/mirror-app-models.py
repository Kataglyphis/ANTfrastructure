#!/usr/bin/env python3
"""Mirror the models an app needs from data locks under models/<sha256>/, with a web manifest. See docs/docs-sites.md#mirroring-an-apps-models"""

from __future__ import annotations

import argparse
import json
import re
import runpy
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

# The hub's one downloader: its cache, its hash check and its atomic writes.
FETCHER: dict[str, Any] = runpy.run_path(str(Path(__file__).with_name("fetch-data-lock.py")))
FetchError: type[Exception] = FETCHER["FetchError"]
# ModelANT releases every model with both texts, and the site must ship them beside it.
LICENSE_SUFFIXES = (".LICENSE", ".NOTICE")
RELEASE_URL = re.compile(r"https://github\.com/([^/]+/[^/]+)/releases/download/([^/]+)/[^/]+")


class MirrorError(Exception):
    """A requested model, its license texts, its lock or the target tree do not hold."""


def lock_rows(lock: Path, root: Path) -> tuple[str, dict[str, tuple[str, str, int]]]:
    """The lock's path below root and its rows by file: (sha256, url, line)."""
    try:
        relative = lock.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        raise MirrorError(f"{lock} is outside {root}: the manifest names each lock by its path in the repository") from None
    lines = {fields[1]: number for number, line in enumerate(lock.read_text(encoding="utf-8").splitlines(), 1)
             if len(fields := line.split()) == 3 and not fields[0].startswith("#")}
    return relative, {name: (sha, url, lines[name]) for sha, name, url in FETCHER["read_lock"](lock)}


def wanted_files(lock: Path, model: str, rows: dict[str, tuple[str, str, int]]) -> list[str]:
    """The model and its license texts, refused when the lock lacks one or the model is an archive."""
    if model not in rows:
        raise MirrorError(f"{model} is not in {lock}")
    if model.endswith(FETCHER["ARCHIVE_SUFFIXES"]):
        raise MirrorError(f"{model} is an archive; the mirror serves single files the browser fetches whole")
    texts = [Path(model).stem + suffix for suffix in LICENSE_SUFFIXES]
    missing = [name for name in texts if name not in rows]
    if missing:
        raise MirrorError(f"{model}: {lock} has no {', '.join(missing)}; a model never ships without its license texts")
    return [model, *texts]


def mirror_file(lock: Path, name: str, row: tuple[str, str, int], relative: str, work: Path, cache: Path) -> dict[str, Any]:
    """One locked file fetched to <work>/<sha256>/<name>, and its manifest entry."""
    sha, url, line = row
    FETCHER["fetch"](lock, work / sha, cache, False, [name])
    return {"file": name, "path": f"models/{sha}/{name}", "sha256": sha, "size": (work / sha / name).stat().st_size,
            "lock": {"path": relative, "line": line, "url": url}}


def mirror_model(lock: Path, model: str, root: Path, work: Path, cache: Path) -> dict[str, Any]:
    """One model and its license texts in the work tree, and the model's manifest entry."""
    relative, rows = lock_rows(lock, root)
    model_file, *texts = (mirror_file(lock, name, rows[name], relative, work, cache)
                          for name in wanted_files(lock, model, rows))
    release = RELEASE_URL.fullmatch(model_file["lock"]["url"])
    return {"name": Path(model).stem, **model_file, "licenses": texts,
            "release": {"repository": release[1], "tag": release[2]} if release else None}


def mirror(out: Path, models: list[tuple[Path, str]], root: Path, cache: Path) -> dict[str, Any]:
    """Every model into <out>/models/ by one rename, with models/manifest.json; nothing is written on a refusal."""
    if not out.is_dir():
        raise MirrorError(f"{out} is not a directory: the app's build wrote nothing there")
    target = out / "models"
    if target.exists():
        raise MirrorError(f"{target} exists; the mirror never mixes with older files")
    names = [model for _, model in models]
    if len(set(names)) != len(names):
        raise MirrorError("a model is named twice")
    work = Path(tempfile.mkdtemp(prefix=".models-mirror-", dir=out))
    try:
        manifest = {"schema_version": 1, "models": [mirror_model(lock, model, root, work, cache) for lock, model in models]}
        (work / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        work.chmod(0o755)
        work.rename(target)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return manifest


def arguments(argv: list[str]) -> argparse.Namespace:
    """The command line."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True, help="the app's directory; models/ is written below it")
    parser.add_argument("--model", nargs=2, action="append", required=True, metavar=("LOCK", "FILE"),
                        help="a model file of a data lock, with its <name>.LICENSE and <name>.NOTICE; repeatable")
    parser.add_argument("--root", type=Path, default=Path.cwd(), help="the repository; the manifest names locks below it")
    parser.add_argument("--cache", type=Path, help="default: the fetcher's model cache")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    """Command line entry point; 1 on a refusal, 2 on bad arguments."""
    args = arguments(argv)
    models = [(Path(lock), name) for lock, name in args.model]
    try:
        manifest = mirror(args.out, models, args.root, args.cache or FETCHER["default_cache"](False))
    except (MirrorError, FetchError, OSError, ValueError) as error:
        print(f"MODEL-MIRROR FAIL: {error}", file=sys.stderr)
        return 1
    for model in manifest["models"]:
        print(f"MODEL-MIRROR OK: {model['file']} -> {model['path']} with {len(model['licenses'])} license texts")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
