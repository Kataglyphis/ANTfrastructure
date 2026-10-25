#!/usr/bin/env python3
"""Fetch what a data lock names, checked by SHA-256, through a cache. See docs/data-repositories.md#the-hubs-fetcher"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import os
import shutil
import sys
import tarfile
import tempfile
import time
import urllib.request
from collections.abc import Generator
from pathlib import Path

ATTEMPTS = 3
RETRY_DELAY_SECONDS = 5.0
TIMEOUT_SECONDS = 60.0
LOCK_TIMEOUT_SECONDS = 1800
CHUNK = 1 << 20
STAMP = ".assetant-sha256"
ARCHIVE_SUFFIXES = (".tar.xz", ".tar.gz", ".tgz")
CACHES = {False: ("KATAGLYPHIS_MODEL_CACHE", "kataglyphis-models"),
          True: ("KATAGLYPHIS_ASSET_CACHE", "kataglyphis-assets")}


class FetchError(Exception):
    """A lock line is malformed, a download failed or differs, or a target is not this fetcher's."""


def default_cache(archives: bool) -> Path:
    """$KATAGLYPHIS_MODEL_CACHE or $KATAGLYPHIS_ASSET_CACHE, else under %LOCALAPPDATA% or ~/.cache."""
    env, leaf = CACHES[archives]
    if os.getenv(env):
        return Path(os.environ[env])
    if sys.platform == "win32":
        local = os.getenv("LOCALAPPDATA")
        return (Path(local) if local else Path.home() / "AppData" / "Local") / leaf
    xdg = os.getenv("XDG_CACHE_HOME")
    return (Path(xdg) if xdg else Path.home() / ".cache") / leaf


def read_lock(lock: Path) -> list[tuple[str, str, str]]:
    """The lock's (sha256, file, url) rows; blank lines and # comments are skipped."""
    rows: list[tuple[str, str, str]] = []
    for number, line in enumerate(lock.read_text(encoding="utf-8").splitlines(), 1):
        fields = line.split()
        if not fields or fields[0].startswith("#"):
            continue
        where = f"{lock}:{number}"
        if len(fields) != 3:
            raise FetchError(f"{where}: expected 'sha256 file url', got {line!r}")
        sha, name, url = fields[0].lower(), fields[1], fields[2]
        if len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha):
            raise FetchError(f"{where}: {fields[0]!r} is no sha256")
        if Path(name).name != name or name in (".", ".."):
            raise FetchError(f"{where}: {name!r} is not a plain file name")
        if any(name == row[1] for row in rows):
            raise FetchError(f"{where}: a second line for {name}")
        rows.append((sha, name, url))
    return rows


def sha256_of(path: Path) -> str:
    """The file's SHA-256 as lowercase hex."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(CHUNK):
            digest.update(chunk)
    return digest.hexdigest()


def matches(path: Path, sha: str) -> bool:
    """True when the path is a file with that SHA-256."""
    return path.is_file() and sha256_of(path) == sha


def download(url: str, part: Path, offline_hint: Path) -> None:
    """The URL into part, three attempts; the bytes are checked by the caller."""
    if not url.startswith(("https://", "http://", "file:")):
        raise FetchError(f"{url}: only https, http and file URLs are fetched")
    # A local file does not appear by waiting.
    attempts = 1 if url.startswith("file:") else ATTEMPTS
    for attempt in range(1, attempts + 1):
        try:
            # The scheme is checked above; the lock's SHA-256 checks the bytes.
            with (
                urllib.request.urlopen(url, timeout=TIMEOUT_SECONDS) as response,  # nosec B310
                part.open("wb") as out,
            ):
                shutil.copyfileobj(response, out, CHUNK)
        except OSError as exc:
            if attempt == attempts:
                raise FetchError(f"download failed: {url}: {exc}; offline, put the file at {offline_hint}") from exc
            time.sleep(RETRY_DELAY_SECONDS * attempt)
        else:
            return


def cached_copy(sha: str, name: str, url: str, cache: Path) -> Path:
    """The verified file in the cache as <sha256>-<file>, downloaded when no copy there matches."""
    cached = cache / f"{sha}-{name}"
    # A bare <sha256> is how the first model fetchers named their cache entries.
    for candidate in (cached, cache / sha):
        if matches(candidate, sha):
            return candidate
    cached.unlink(missing_ok=True)
    handle, temp = tempfile.mkstemp(prefix=".part.", dir=cache)
    os.close(handle)
    part = Path(temp)
    try:
        download(url, part, cached)
        got = sha256_of(part)
        if got != sha:
            raise FetchError(f"{url}: sha256 {got}, the lock says {sha}")
        part.replace(cached)
    finally:
        part.unlink(missing_ok=True)
    return cached


def place_file(cached: Path, target: Path) -> None:
    """The cached file at target, by one rename, readable by every user; a failure leaves no part behind."""
    part = target.with_name(target.name + ".part")
    try:
        shutil.copyfile(cached, part)
        # A umask of 077 would make it 0600, and a service user must read the model.
        part.chmod(0o644)
        part.replace(target)
    except BaseException:
        part.unlink(missing_ok=True)
        raise


def archive_name(file: str) -> str:
    """<name>.tar.xz (or .tar.gz, .tgz) unpacks to <name>/."""
    for suffix in ARCHIVE_SUFFIXES:
        if file.endswith(suffix) and len(file) > len(suffix):
            return file[: -len(suffix)]
    raise FetchError(f"{file} is no {', '.join(ARCHIVE_SUFFIXES)} archive")


def file_count(directory: Path) -> int:
    """The files under the directory, its stamp not counted."""
    return sum(1 for p in directory.rglob("*") if p.is_file() and p.name != STAMP)


def up_to_date(target: Path, sha: str) -> bool:
    """True when the stamp names this archive and the file count it extracted."""
    stamp = target / STAMP
    if not stamp.is_file():
        if target.exists():
            raise FetchError(f"{target} exists but was not fetched (no {STAMP} in it): move it away; "
                             "this fetcher replaces only what it extracted itself")
        return False
    # The count catches files gone under a kept stamp, as after checking out a commit that still tracked them.
    return stamp.read_text(encoding="utf-8").strip() == f"{sha} {file_count(target)}"


def extract(cached: Path, sha: str, target: Path) -> None:
    """The archive's <name>/ at target, stamped, by one rename; a cut-off extraction leaves only a scratch dir."""
    name = target.name
    with tarfile.open(cached) as archive:
        stray = [m.name for m in archive.getmembers() if m.name.split("/")[0] != name]
        if stray:
            raise FetchError(f"{cached.name} holds {stray[0]}, outside the {name}/ every archive unpacks to")
        scratch = Path(tempfile.mkdtemp(prefix=f".{name}.", dir=target.parent))
        try:
            archive.extractall(scratch, filter="data")
            fresh = scratch / name
            now = time.time()
            # Archives are packed with mtime 0; a build would take every file for older than its outputs.
            for path in [fresh, *fresh.rglob("*")]:
                if not path.is_symlink():
                    os.utime(path, (now, now))
            (fresh / STAMP).write_text(f"{sha} {file_count(fresh)}\n", encoding="utf-8")
            if target.exists():
                shutil.rmtree(target)
            fresh.replace(target)
        finally:
            shutil.rmtree(scratch, ignore_errors=True)


@contextlib.contextmanager
def cache_lock(cache: Path) -> Generator[None, None, None]:
    """One fetch per cache at a time: two would write the same targets."""
    with (cache / ".lock").open("a+b") as handle:
        deadline = time.monotonic() + LOCK_TIMEOUT_SECONDS
        while True:
            try:
                if sys.platform == "win32":
                    import msvcrt

                    handle.seek(0)
                    msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl

                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise FetchError(f"{cache / '.lock'} stayed locked for {LOCK_TIMEOUT_SECONDS} s") from None
                time.sleep(1)
        yield


def fetch(lock: Path, dest: Path, cache: Path, archives: bool, only: list[str]) -> int:
    """Every row of the lock (or of --only) into dest; returns how many it had to write."""
    rows = read_lock(lock)
    names = {(archive_name(name) if archives else name): (sha, name, url) for sha, name, url in rows}
    missing = [name for name in only if name not in names]
    if missing:
        raise FetchError(f"{', '.join(missing)} not in {lock}")
    dest.mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    written = 0
    with cache_lock(cache):
        for key, (sha, name, url) in names.items():
            if only and key not in only:
                continue
            target = dest / key
            if (up_to_date(target, sha) if archives else matches(target, sha)):
                continue
            cached = cached_copy(sha, name, url, cache)
            if archives:
                extract(cached, sha, target)
            else:
                place_file(cached, target)
            sys.stdout.write(f"fetched {target} (sha256 {sha[:12]})\n")
            written += 1
    return written


def main(argv: list[str] | None = None) -> int:
    """Command line entry point; 1 on a failed fetch, 2 on bad arguments."""
    parser = argparse.ArgumentParser(description="Fetch what a data lock names, checked by SHA-256.")
    parser.add_argument("--lock", type=Path, required=True, help="lines of 'sha256 file url'")
    parser.add_argument("--dest", type=Path, help="default: the lock's directory")
    parser.add_argument("--extract", action="store_true",
                        help="each file is an archive unpacking to <name>/, stamped with its sha256 and file count")
    parser.add_argument("--only", action="append", default=[], metavar="NAME",
                        help="fetch only this file (an archive: its <name>); repeatable")
    parser.add_argument("--cache", type=Path, help="default: $KATAGLYPHIS_MODEL_CACHE, or $KATAGLYPHIS_ASSET_CACHE with --extract")
    args = parser.parse_args(argv)
    if not args.lock.is_file():
        sys.stderr.write(f"no lock file {args.lock}\n")
        return 2
    dest = args.dest if args.dest is not None else args.lock.parent
    try:
        fetch(args.lock, dest, args.cache or default_cache(args.extract), args.extract, args.only)
    except FetchError as exc:
        sys.stderr.write(f"{exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
