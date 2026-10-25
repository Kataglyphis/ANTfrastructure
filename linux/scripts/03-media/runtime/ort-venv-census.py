#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""ONNX Runtime census of one Python environment: every ORT distribution is a chain wheel.

Run by the interpreter under test: `python -I ort-venv-census.py --check|--purge-list --store DIR`.
assemble-torch-app.sh runs this file; Build-TorchApp.ps1 runs a staged copy of the same file.
Verdicts and fixes: docs/failure-modes.md#the-torch-stage-fails-with-ort-census-fail

NOT covered: whether the store wheel was compiled by the chain (the image census, G1); files
installed outside site-packages; ORT bytes vendored under another name and import package (G1).
"""

import argparse
import hashlib
import importlib.metadata as md
import importlib.util
import os
import re
import struct
import sys
import zipfile
import zlib
from collections.abc import Collection, Sequence
from email.parser import HeaderParser
from typing import IO

ORT_DIST = re.compile(r"^onnxruntime(-|$)")
ORT_RUNTIME = re.compile(r"^onnxruntime(-(?!genai$|extensions$)[a-z0-9]+)?$")
ORT_PACKAGES = ("onnxruntime", "onnxruntime_genai", "onnxruntime_extensions")
DATA_LIB = re.compile(r"^[^/]+\.data/(?:purelib|platlib)/(.+)$")
WHEEL_METADATA = re.compile(r"^[^/]+\.dist-info/METADATA$")
# Input and archive errors become findings; unexpected implementation errors keep their traceback.
CENSUS_FAILURES = (
    OSError,
    zipfile.BadZipFile,
    zipfile.LargeZipFile,
    EOFError,
    KeyError,
    ValueError,
    RuntimeError,
    struct.error,
    zlib.error,
)


def norm(name: str | None) -> str:
    return re.sub(r"[-_.]+", "-", name or "").lower()


def sha256(stream: IO[bytes]) -> str:
    digest = hashlib.sha256()
    while block := stream.read(1024 * 1024):
        digest.update(block)
    return digest.hexdigest()


def real(path: str | os.PathLike[str]) -> str:
    return os.path.normcase(os.path.realpath(path))


def header(dist: md.Distribution, key: str) -> str:
    meta = dist.metadata
    return (meta.get(key) if meta is not None else None) or ""


def payload(member: str) -> str | None:
    """Where a wheel member lands under site-packages; None for metadata and non-lib .data."""
    top = member.split("/", 1)[0]
    if member.endswith("/") or top.endswith(".dist-info"):
        return None
    lib = DATA_LIB.match(member)
    if lib:
        return lib.group(1)
    return None if top.endswith(".data") else member


def listed(dist: md.Distribution) -> set[str]:
    """The RECORD's site-packages payload: no metadata, no ../ launchers, no bytecode."""
    out = set()
    for path in dist.files or ():
        parts = path.parts
        if (
            parts
            and parts[0] != ".."
            and not parts[0].endswith(".dist-info")
            and "__pycache__" not in parts
        ):
            out.add("/".join(parts))
    return out


def packages(dist: md.Distribution) -> list[str]:
    tops = {rel.split("/", 1)[0].split(".", 1)[0] for rel in listed(dist)}
    tops.update((dist.read_text("top_level.txt") or "").split())
    return sorted(t for t in tops if t in ORT_PACKAGES)


def candidates() -> dict[tuple[str, str], tuple[md.Distribution, list[str]]]:
    """{(name, site): (dist, owned packages)} for every ORT distribution on sys.path."""
    found: dict[tuple[str, str], tuple[md.Distribution, list[str]]] = {}
    for dist in md.distributions():
        name = norm(header(dist, "Name"))
        key = (name, real(str(dist.locate_file(""))))
        owns = packages(dist)
        if (ORT_DIST.match(name) or owns) and key not in found:
            found[key] = (dist, owns)
    return found


def label(key: tuple[str, str], dist: md.Distribution) -> str:
    return f"{key[0] or '<unnamed>'} {header(dist, 'Version') or '?'} at {os.path.realpath(str(dist.locate_file('')))}"


def summary(paths: Collection[str], what: str) -> str:
    return f"{len(paths)} file(s) {what}, e.g. {', '.join(sorted(paths)[:3])}"


def store_index(store: str) -> dict[tuple[str, str], str]:
    """{(name, version): wheel path} from each store wheel's own METADATA."""
    index: dict[tuple[str, str], str] = {}
    for entry in sorted(os.listdir(store)):
        if not entry.endswith(".whl"):
            continue
        path = os.path.join(store, entry)
        with zipfile.ZipFile(path) as whl:
            meta = [n for n in whl.namelist() if WHEEL_METADATA.match(n)]
            head = (
                HeaderParser().parsestr(whl.read(meta[0]).decode("utf-8", "replace"))
                if len(meta) == 1
                else {}
            )
        index[(norm(head.get("Name")), head.get("Version") or "")] = path
    return index


def compare(dist: md.Distribution, wheel: str) -> list[str]:
    """What differs between an installed distribution and its store wheel; empty = same bytes."""
    if dist.files is None:
        return ["has no RECORD, so its files cannot be proven"]
    missing, differ, members = [], [], set()
    with zipfile.ZipFile(wheel) as whl:
        for member in whl.namelist():
            rel = payload(member)
            if rel is None:
                continue
            members.add(rel)
            path = str(dist.locate_file(rel))
            if not os.path.isfile(path):
                missing.append(rel)
                continue
            with whl.open(member) as want, open(path, "rb") as have:
                if sha256(want) != sha256(have):
                    differ.append(rel)
    extra = listed(dist) - members
    return [
        summary(paths, what)
        for paths, what in (
            (differ, "differ from the chain wheel's bytes"),
            (missing, "of the chain wheel are missing"),
            (extra, "are installed but not in the chain wheel"),
        )
        if paths
    ]


def import_findings(pkg: str, owners: Sequence[md.Distribution]) -> list[str]:
    """The import must resolve to an owner's file, and the package dir may hold only owned files."""
    try:
        spec = importlib.util.find_spec(pkg)
    except (ImportError, ValueError) as exc:
        return [f"{pkg} cannot be located: {exc!s}"]
    if spec is None:
        return ["import onnxruntime finds nothing"] if pkg == "onnxruntime" else []
    owned = {real(str(d.locate_file(rel))) for d in owners for rel in listed(d)}
    out = []
    if spec.origin and real(spec.origin) not in owned:
        out.append(
            f"import {pkg} resolves to {spec.origin}, which no owning distribution installed"
        )
    stray = []
    for where in spec.submodule_search_locations or ():
        for base, dirs, names in os.walk(where):
            dirs[:] = [d for d in dirs if d != "__pycache__"]
            stray.extend(
                os.path.join(base, n)
                for n in names
                if real(os.path.join(base, n)) not in owned
            )
    if stray:
        out.append(summary(stray, f"in the {pkg} package are in no owner's RECORD"))
    return out


def owner_findings(found: dict[tuple[str, str], tuple[md.Distribution, list[str]]]) -> list[str]:
    findings = []
    for pkg in ORT_PACKAGES:
        owners = [key for key in sorted(found) if pkg in found[key][1]]
        if len(owners) > 1 or (pkg == "onnxruntime" and not owners):
            want = "exactly one" if pkg == "onnxruntime" else "at most one"
            names = "; ".join(label(k, found[k][0]) for k in owners) or "none"
            findings.append(
                f"the {pkg} import package has {len(owners)} owners ({names}), expected {want}"
            )
        findings.extend(import_findings(pkg, [found[k][0] for k in owners]))
    return findings


def check(store: str) -> tuple[list[str], list[str]]:
    """(findings, chain labels) for the environment against the chain wheel store."""
    index = store_index(store)
    findings, chain = [], []
    if not any(ORT_RUNTIME.match(name) for name, _ in index):
        findings.append(f"the chain wheel store {store} holds no onnxruntime wheel")
    found = candidates()
    for key in sorted(found):
        dist = found[key][0]
        wheel = index.get((key[0], header(dist, "Version")))
        if wheel is None:
            findings.append(
                f"{label(key, dist)} is not a chain wheel: the store {store} has no wheel of that name and version"
            )
            continue
        problems = compare(dist, wheel)
        findings.extend(f"{label(key, dist)}: {problem}" for problem in problems)
        if not problems:
            chain.append(f"{label(key, dist)} = {os.path.basename(wheel)}")
    findings.extend(owner_findings(found))
    return findings, chain


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="ONNX Runtime census of this interpreter's environment"
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--check",
        action="store_true",
        help="fail unless every ORT distribution is a chain wheel",
    )
    mode.add_argument(
        "--purge-list",
        action="store_true",
        help="print the ORT distributions to uninstall",
    )
    parser.add_argument("--store", default="", help="the chain wheel store")
    args = parser.parse_args(argv)
    if args.purge_list:
        for name in sorted({key[0] for key in candidates() if key[0]}):
            print(f"ORT-CENSUS PURGE {name}")
        return 0
    try:
        findings, chain = check(args.store)
    except CENSUS_FAILURES as exc:
        findings, chain = (
            [f"the census could not complete: {type(exc).__name__}: {exc!s}"],
            [],
        )
    for line in chain:
        print(f"ORT-CENSUS chain {line}")
    for finding in findings:
        print(f"ORT-CENSUS FAIL {finding}")
    if findings:
        print(f"ORT-CENSUS FAILED: {len(findings)} finding(s)")
        return 1
    print(f"ORT-CENSUS PASS: {len(chain)} chain distribution(s) from {args.store}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
