#!/usr/bin/env python3
"""The Noto fallback fonts Flutter's web engine requests, from the hub's lock into a web build. See linux/webserver/README.md#fallback-fonts-from-the-site"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import os
import re
import shutil
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
# The engine's default fontFallbackBaseUrl: every lock URL is this plus the path the engine asks the site for.
GSTATIC = "https://fonts.gstatic.com/s/"
ENGINE_DATA = Path("engine/src/flutter/lib/web_ui/lib/src/engine/font_fallback_data.dart")


def _fetcher():
    """The hub's lock fetcher, whose file name is no module name."""
    spec = importlib.util.spec_from_file_location("fetch_data_lock", HERE.parents[1] / "lib" / "fetch-data-lock.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def flutter_root() -> Path | None:
    """$FLUTTER_ROOT, else the SDK of the flutter on PATH."""
    if os.getenv("FLUTTER_ROOT"):
        return Path(os.environ["FLUTTER_ROOT"])
    found = shutil.which("flutter")
    return Path(os.path.realpath(found)).parents[1] if found else None


def engine_paths(data: Path) -> list[str]:
    """Every <family>/<version>/<file> the engine can request, in its order."""
    return re.findall(r"NotoFont\(\s*'[^']+',\s*'([^']+)'", data.read_text(encoding="utf-8"))


def check_against_engine(rows, requested: list[str]) -> list[str]:
    """A lock row the engine never requests, or a chunk of a locked family the lock lacks."""
    problems = []
    locked = set()
    for _sha, name, url in rows:
        rel = url[len(GSTATIC):] if url.startswith(GSTATIC) else None
        if rel is None or rel.rsplit("/", 1)[-1] != name:
            problems.append(f"{name}: {url} is not {GSTATIC}<family>/<version>/{name}")
        elif rel not in requested:
            problems.append(f"{name}: this engine never requests {rel}; Flutter moved, re-pin with --print-lock {rel.split('/')[0]}")
        else:
            locked.add(rel)
    families = {rel.split("/")[0] for rel in locked}
    missing = [rel for rel in requested if rel.split("/")[0] in families and rel not in locked]
    problems += [f"{rel}: the engine requests it for a locked family, the lock lacks it" for rel in missing]
    return problems


def print_lock(families: list[str], requested: list[str]) -> int:
    """Lock lines for every chunk of these families, hashed from a fresh download."""
    wanted = [rel for rel in requested if rel.split("/")[0] in families]
    unknown = sorted(set(families) - {rel.split("/")[0] for rel in wanted})
    if unknown:
        sys.stderr.write(f"the engine has no family {', '.join(unknown)}\n")
        return 2
    for rel in wanted:
        # The URL is the constant GSTATIC plus a path from the engine's own list.
        with urllib.request.urlopen(GSTATIC + rel, timeout=60) as response:  # noqa: S310  # nosec B310
            sha = hashlib.sha256(response.read()).hexdigest()
        sys.stdout.write(f"{sha}  {rel.rsplit('/', 1)[-1]}  {GSTATIC}{rel}\n")
    return 0


def engine_data(given: Path | None) -> Path | None:
    """--engine-data, else the list in the Flutter SDK on PATH; None when it is no file."""
    if given is None:
        root = flutter_root()
        given = root / ENGINE_DATA if root else None
    return given if given is not None and given.is_file() else None


def default_cache() -> Path:
    """$KATAGLYPHIS_FONT_CACHE, else kataglyphis-fonts under $XDG_CACHE_HOME or ~/.cache."""
    if os.getenv("KATAGLYPHIS_FONT_CACHE"):
        return Path(os.environ["KATAGLYPHIS_FONT_CACHE"])
    return Path(os.getenv("XDG_CACHE_HOME") or Path.home() / ".cache") / "kataglyphis-fonts"


def place(lock, rows, dest: Path, cache: Path) -> None:
    """Every row at <dest>/<family>/<version>/<file>, through the cache; the fetcher's FetchError on a failure."""
    cache.mkdir(parents=True, exist_ok=True)
    with lock.cache_lock(cache):
        for sha, name, url in rows:
            target = dest / url[len(GSTATIC):]
            if lock.matches(target, sha):
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            lock.place_file(lock.cached_copy(sha, name, url, cache), target)


def main(argv: list[str] | None = None) -> int:
    """Command line entry point; 1 on a failed fetch or a lock the engine disagrees with, 2 on bad arguments."""
    parser = argparse.ArgumentParser(description=__doc__.split(". See")[0])
    parser.add_argument("--dest", type=Path, help="the directory the app's fontFallbackBaseUrl names, e.g. build/web/fallback-fonts")
    parser.add_argument("--lock", type=Path, default=HERE / "fallback-fonts.lock")
    parser.add_argument("--engine-data", type=Path, help=f"default: <Flutter SDK>/{ENGINE_DATA.as_posix()}")
    parser.add_argument("--cache", type=Path, help="default: $KATAGLYPHIS_FONT_CACHE, else kataglyphis-fonts under ~/.cache")
    parser.add_argument("--check", action="store_true", help="only compare the lock with the engine's list; fetch nothing")
    parser.add_argument("--print-lock", nargs="+", metavar="FAMILY", help="print lock lines for every chunk of these families and exit")
    args = parser.parse_args(argv)
    data = engine_data(args.engine_data)
    if data is None:
        sys.stderr.write(f"no engine font list at {args.engine_data or '<Flutter SDK>/' + ENGINE_DATA.as_posix()}: pass --engine-data\n")
        return 2
    requested = engine_paths(data)
    if args.print_lock:
        return print_lock(args.print_lock, requested)
    if args.dest is None and not args.check:
        parser.error("--dest is required")
    lock = _fetcher()
    try:
        rows = lock.read_lock(args.lock)
    except (OSError, lock.FetchError) as exc:
        sys.stderr.write(f"{exc}\n")
        return 2
    problems = check_against_engine(rows, requested)
    for problem in problems:
        sys.stderr.write(f"FAIL: {problem}\n")
    if problems or args.check:
        return 1 if problems else 0
    try:
        place(lock, rows, args.dest, args.cache or default_cache())
    except lock.FetchError as exc:
        sys.stderr.write(f"{exc}\n")
        return 1
    families = {url[len(GSTATIC):].split("/")[0] for _sha, _name, url in rows}
    sys.stdout.write(f"{len(rows)} fallback fonts of {len(families)} families in {args.dest}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
