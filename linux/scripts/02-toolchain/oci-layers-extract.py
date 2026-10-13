#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""Write an allowlist of paths from an image's layers into a directory, applying them in order with OCI whiteouts.

Usage: oci-layers-extract.py --layout DIR --dest DIR [--jobs N] [--delete-blobs] PATH...; see docs/riscv64-cross-test-lanes.md#the-sysroot-from-the-registry-skopeo
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import multiprocessing
import os
import posixpath
import shutil
import stat
import sys
import tarfile
import time

WHITEOUT = ".wh."
OPAQUE = ".wh..wh..opq"
# AUFS bookkeeping (.wh..wh.plnk, .wh..wh.aufs) is not image content.
AUFS_META = ".wh..wh."
CHUNK = 1 << 20


class ExtractError(Exception):
    """The layout or a layer cannot be applied as the OCI layer rules say."""


def norm(name: str) -> str:
    """A member name relative to the image root; a '..' component is refused, never resolved."""
    parts = []
    for part in name.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            raise ExtractError("member %r climbs out of the image root" % name)
        parts.append(part)
    return "/".join(parts)


class Allow:
    """The allowlist: a path selects itself and everything under it, as tar's member names do."""

    def __init__(self, paths):
        self.paths = tuple(norm(p) for p in paths)

    def selects(self, name: str) -> bool:
        return any(name == p or name.startswith(p + "/") for p in self.paths)

    def touches(self, name: str) -> bool:
        """True when removing name can remove allowlisted content: it is selected or an ancestor of an entry."""
        return name == "" or self.selects(name) or any(p.startswith(name + "/") for p in self.paths)


def read_layers(layout: str) -> list[tuple[str, int]]:
    """(blob path, size) per layer, bottom first, from a `skopeo copy ... dir:` layout."""
    try:
        with open(os.path.join(layout, "manifest.json"), encoding="utf-8") as fh:
            manifest = json.load(fh)
    except (OSError, ValueError) as exc:
        raise ExtractError("%s holds no readable manifest.json: %s" % (layout, exc)) from exc
    layers = manifest.get("layers")
    if manifest.get("schemaVersion") != 2 or not isinstance(layers, list) or not layers:
        raise ExtractError("%s/manifest.json is not a single-platform image manifest" % layout)
    out = []
    for layer in layers:
        blob = os.path.join(layout, layer["digest"].partition(":")[2])
        if not os.path.isfile(blob):
            raise ExtractError("layer blob missing from the layout: %s" % layer["digest"])
        out.append((blob, int(layer.get("size", 0))))
    return out


def is_real_dir(path: str) -> bool:
    try:
        return stat.S_ISDIR(os.lstat(path).st_mode)
    except FileNotFoundError:
        return False


def remove(path: str) -> None:
    if is_real_dir(path):
        shutil.rmtree(path)
    elif os.path.lexists(path):
        os.unlink(path)


def real_dir(root: str, rel: str) -> str | None:
    """root/rel when every component is a real directory, so nothing is reached through a symlink."""
    cur = root
    for part in rel.split("/") if rel else ():
        cur = os.path.join(cur, part)
        if not is_real_dir(cur):
            return None
    return cur


def make_parents(root: str, name: str) -> str:
    """The path of name under root with its parents created as real directories."""
    cur = root
    parts = name.split("/")
    for part in parts[:-1]:
        cur = os.path.join(cur, part)
        if is_real_dir(cur):
            continue
        if os.path.lexists(cur):
            raise ExtractError("%s would be written through %s, which is not a directory" % (name, cur))
        os.mkdir(cur)
    return os.path.join(cur, parts[-1])


def write_file(tar: tarfile.TarFile, member: tarfile.TarInfo, path: str, umask: int) -> None:
    src = tar.extractfile(member)
    with src, open(path, "wb") as dst:
        shutil.copyfileobj(src, dst, CHUNK)
    # A non-root GNU tar applies the umask and drops setuid, setgid and sticky; export mode extracts that way.
    os.chmod(path, member.mode & 0o777 & ~umask)
    os.utime(path, (member.mtime, member.mtime))


def place(tar: tarfile.TarFile, member: tarfile.TarInfo, name: str, staging: str, rec: dict, umask: int) -> None:
    """One selected member into the layer's staging tree; later members of the same name win."""
    path = make_parents(staging, name)
    if not (member.isdir() and is_real_dir(path)):
        remove(path)
    if member.isdir():
        os.makedirs(path, exist_ok=True)
        rec["dirs"][name] = (member.mode, member.mtime)
    elif member.isreg():
        write_file(tar, member, path, umask)
        rec["files"] += 1
        rec["bytes"] += member.size
    elif member.issym():
        os.symlink(member.linkname, path)
    elif member.isfifo():
        os.mkfifo(path, member.mode & 0o777 & ~umask)
    else:
        raise ExtractError("%s: a device or unknown member (type %r) cannot be written unprivileged" % (name, member.type))


def scan(tar: tarfile.TarFile, staging: str, allow: Allow, rec: dict, umask: int) -> None:
    for member in tar:
        # A stream keeps every header it read; a layer of 100k files would hold them all.
        del tar.members[:]
        name = norm(member.name)
        parent, base = posixpath.split(name)
        if not name or AUFS_META in parent:
            continue
        if base == OPAQUE:
            if allow.touches(parent):
                rec["opaque"].append(parent)
        elif base.startswith(AUFS_META):
            continue
        elif base.startswith(WHITEOUT):
            target = posixpath.join(parent, base[len(WHITEOUT):])
            if allow.touches(target):
                rec["whiteouts"].append(target)
        elif not allow.selects(name):
            continue
        elif member.islnk():
            rec["links"].append((name, norm(member.linkname)))
        else:
            place(tar, member, name, staging, rec, umask)


def copy_link_targets(blob: str, staging: str, links: list, umask: int) -> None:
    """Hard links whose target lies outside the allowlist get the target's bytes as their own file."""
    want: dict[str, list[str]] = {}
    for name, target in links:
        want.setdefault(target, []).append(name)
    with open(blob, "rb") as raw, tarfile.open(fileobj=raw, mode="r|*") as tar:
        for member in tar:
            names = want.pop(norm(member.name), None) if member.isreg() else None
            for name in names or ():
                path = make_parents(staging, name)
                remove(path)
                write_file(tar, member, path, umask)
            del tar.members[:]
    if want:
        raise ExtractError("hard link target(s) not in the same layer: %s" % ", ".join(sorted(want)))


def extract_layer(blob: str, staging: str, paths: tuple, umask: int) -> dict:
    """The allowlisted members of one layer into staging, plus what the merge must apply."""
    allow = Allow(paths)
    rec = {"whiteouts": [], "opaque": [], "dirs": {}, "links": [], "files": 0, "bytes": 0}
    os.makedirs(staging)
    # Default bufsize: the stream re-slices its buffer tail on every header read, so 1 MiB ran 3.7x slower.
    with open(blob, "rb") as raw, tarfile.open(fileobj=raw, mode="r|*") as tar:
        scan(tar, staging, allow, rec, umask)
    outside = [(n, t) for n, t in rec["links"] if not allow.selects(t)]
    if outside:
        copy_link_targets(blob, staging, outside, umask)
        rec["links"] = [(n, t) for n, t in rec["links"] if allow.selects(t)]
    return rec


def forget(dirs: dict, rel: str, keep_self: bool) -> None:
    prefix = rel + "/" if rel else ""
    for key in [k for k in dirs if k.startswith(prefix) or (k == rel and not keep_self)]:
        del dirs[key]


def link_into(dest: str, name: str, target: str) -> None:
    parent, base = posixpath.split(target)
    d = real_dir(dest, parent)
    src = os.path.join(d, base) if d is not None else ""
    if not src or not os.path.isfile(src) or os.path.islink(src):
        raise ExtractError("hard link %s names %s, which is not a regular file here" % (name, target))
    path = make_parents(dest, name)
    remove(path)
    os.link(src, path)


def merge_tree(src: str, dst: str) -> None:
    """Moves src over dst: directories merge, anything else replaces what dst holds at that name."""
    for name in os.listdir(src):
        s, d = os.path.join(src, name), os.path.join(dst, name)
        if is_real_dir(s) and is_real_dir(d):
            merge_tree(s, d)
        else:
            remove(d)
            os.rename(s, d)


def apply_layer(dest: str, staging: str, rec: dict, dirs: dict) -> None:
    """Whiteouts and opaque directories hide lower content first; then this layer's own entries land."""
    for rel in rec["whiteouts"]:
        parent, base = posixpath.split(rel)
        d = real_dir(dest, parent)
        if d is not None:
            remove(os.path.join(d, base))
        forget(dirs, rel, keep_self=False)
    for rel in rec["opaque"]:
        d = real_dir(dest, rel)
        for entry in os.listdir(d) if d is not None else ():
            remove(os.path.join(d, entry))
        forget(dirs, rel, keep_self=True)
    merge_tree(staging, dest)
    dirs.update(rec["dirs"])
    for name, target in rec["links"]:
        link_into(dest, name, target)


def finish_dirs(dest: str, dirs: dict, umask: int) -> None:
    """Directory modes go on last, deepest first, so a read-only directory never blocks a write into it."""
    for rel in sorted(dirs, key=lambda r: r.count("/"), reverse=True):
        path = real_dir(dest, rel)
        if path is not None:
            mode, mtime = dirs[rel]
            os.chmod(path, mode & 0o777 & ~umask)
            os.utime(path, (mtime, mtime))


def run(layout: str, dest: str, paths: list[str], jobs: int, delete_blobs: bool) -> dict:
    layers = read_layers(layout)
    allow = Allow(paths)
    umask = os.umask(0)
    os.umask(umask)
    work = dest.rstrip("/") + ".layers"
    remove(work)
    os.makedirs(work)
    os.makedirs(dest, exist_ok=True)
    if os.listdir(dest):
        raise ExtractError("%s is not empty" % dest)
    refs: dict[str, int] = {}
    for blob, _ in layers:
        refs[blob] = refs.get(blob, 0) + 1
    totals = {"layers": len(layers), "files": 0, "bytes": 0}
    dirs: dict = {}
    # fork: the workers need no re-import, and nothing has started a thread yet.
    ctx = multiprocessing.get_context("fork")
    try:
        with concurrent.futures.ProcessPoolExecutor(max_workers=jobs, mp_context=ctx) as pool:
            # Largest first keeps the longest layer off the tail; the merge still runs in layer order.
            order = sorted(range(len(layers)), key=lambda i: -layers[i][1])
            futures = {i: pool.submit(extract_layer, layers[i][0], os.path.join(work, str(i)), allow.paths, umask)
                       for i in order}
            for i, (blob, _) in enumerate(layers):
                try:
                    rec = futures[i].result()
                except BaseException:
                    pool.shutdown(cancel_futures=True)
                    raise
                apply_layer(dest, os.path.join(work, str(i)), rec, dirs)
                shutil.rmtree(os.path.join(work, str(i)))
                totals["files"] += rec["files"]
                totals["bytes"] += rec["bytes"]
                refs[blob] -= 1
                if delete_blobs and refs[blob] == 0:
                    os.unlink(blob)
    finally:
        remove(work)
    finish_dirs(dest, dirs, umask)
    missing = [p for p in allow.paths if not os.path.lexists(os.path.join(dest, p))]
    if missing:
        raise ExtractError("not in the image: %s; the image contract moved" % ", ".join(missing))
    return totals


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--layout", required=True, help="a skopeo dir: layout (manifest.json + blobs)")
    parser.add_argument("--dest", required=True, help="the directory to write; must be absent or empty")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 1, help="layers decompressed at once")
    parser.add_argument("--delete-blobs", action="store_true", help="unlink each blob once applied")
    parser.add_argument("paths", nargs="+", help="allowlisted paths, relative to the image root")
    args = parser.parse_args(argv[1:])
    start = time.monotonic()
    try:
        totals = run(args.layout, args.dest, args.paths, max(1, args.jobs), args.delete_blobs)
    except (ExtractError, OSError, tarfile.TarError, KeyError) as exc:
        sys.stderr.write("oci-layers-extract.py: %s\n" % exc)
        return 1
    print("oci-layers-extract.py: %d layers, %d files, %.1f MB in %.1f s" % (
        totals["layers"], totals["files"], totals["bytes"] / 1e6, time.monotonic() - start))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
