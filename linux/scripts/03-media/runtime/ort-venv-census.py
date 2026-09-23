#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""ONNX Runtime census of one Python environment: every ORT distribution is a chain wheel.

Run by the interpreter under test: `python -I ort-venv-census.py --check|--purge-list --store DIR`.
assemble-torch-app.sh runs this file; Build-TorchApp.ps1 embeds it verbatim.
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
import sys
import zipfile
from email.parser import HeaderParser

ORT_DIST = re.compile(r"^onnxruntime(-|$)")
ORT_RUNTIME = re.compile(r"^onnxruntime(-(?!genai$|extensions$)[a-z0-9]+)?$")
ORT_PACKAGES = ("onnxruntime", "onnxruntime_genai", "onnxruntime_extensions")
DATA_LIB = re.compile(r"^[^/]+\.data/(?:purelib|platlib)/(.+)$")
WHEEL_METADATA = re.compile(r"^[^/]+\.dist-info/METADATA$")


def norm(name):
    return re.sub(r"[-_.]+", "-", name or "").lower()


def sha256(stream):
    return hashlib.file_digest(stream, "sha256").hexdigest()


def real(path):
    return os.path.normcase(os.path.realpath(path))


def header(dist, key):
    meta = dist.metadata
    return (meta.get(key) if meta is not None else None) or ""


def payload(member):
    """Where a wheel member lands under site-packages; None for metadata and non-lib .data."""
    top = member.split("/", 1)[0]
    if member.endswith("/") or top.endswith(".dist-info"):
        return None
    lib = DATA_LIB.match(member)
    if lib:
        return lib.group(1)
    return None if top.endswith(".data") else member


def listed(dist):
    """The RECORD's site-packages payload: no metadata, no ../ launchers, no bytecode."""
    out = set()
    for path in dist.files or ():
        parts = path.parts
        if parts and parts[0] != ".." and not parts[0].endswith(".dist-info") and "__pycache__" not in parts:
            out.add("/".join(parts))
    return out


def packages(dist):
    tops = {rel.split("/", 1)[0].split(".", 1)[0] for rel in listed(dist)}
    tops.update((dist.read_text("top_level.txt") or "").split())
    return sorted(t for t in tops if t in ORT_PACKAGES)


def candidates():
    """{(name, site): (dist, owned packages)} for every ORT distribution on sys.path."""
    found = {}
    for dist in md.distributions():
        name = norm(header(dist, "Name"))
        key = (name, real(str(dist.locate_file(""))))
        owns = packages(dist)
        if (ORT_DIST.match(name) or owns) and key not in found:
            found[key] = (dist, owns)
    return found


def label(key, dist):
    return "%s %s at %s" % (key[0] or "<unnamed>", header(dist, "Version") or "?", os.path.realpath(str(dist.locate_file(""))))


def summary(paths, what):
    return "%d file(s) %s, e.g. %s" % (len(paths), what, ", ".join(sorted(paths)[:3]))


def store_index(store):
    """{(name, version): wheel path} from each store wheel's own METADATA."""
    index = {}
    for entry in sorted(os.listdir(store)):
        if not entry.endswith(".whl"):
            continue
        path = os.path.join(store, entry)
        with zipfile.ZipFile(path) as whl:
            meta = [n for n in whl.namelist() if WHEEL_METADATA.match(n)]
            head = HeaderParser().parsestr(whl.read(meta[0]).decode("utf-8", "replace")) if len(meta) == 1 else {}
        index[(norm(head.get("Name")), head.get("Version") or "")] = path
    return index


def compare(dist, wheel):
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
    return [summary(paths, what) for paths, what in (
        (differ, "differ from the chain wheel's bytes"),
        (missing, "of the chain wheel are missing"),
        (extra, "are installed but not in the chain wheel")) if paths]


def import_findings(pkg, owners):
    """The import must resolve to an owner's file, and the package dir may hold only owned files."""
    try:
        spec = importlib.util.find_spec(pkg)
    except (ImportError, ValueError) as exc:
        return ["%s cannot be located: %s" % (pkg, exc)]
    if spec is None:
        return ["import onnxruntime finds nothing"] if pkg == "onnxruntime" else []
    owned = {real(str(d.locate_file(rel))) for d in owners for rel in listed(d)}
    out = []
    if spec.origin and real(spec.origin) not in owned:
        out.append("import %s resolves to %s, which no owning distribution installed" % (pkg, spec.origin))
    stray = []
    for where in spec.submodule_search_locations or ():
        for base, dirs, names in os.walk(where):
            dirs[:] = [d for d in dirs if d != "__pycache__"]
            stray.extend(os.path.join(base, n) for n in names if real(os.path.join(base, n)) not in owned)
    if stray:
        out.append(summary(stray, "in the %s package are in no owner's RECORD" % pkg))
    return out


def owner_findings(found):
    findings = []
    for pkg in ORT_PACKAGES:
        owners = [key for key in sorted(found) if pkg in found[key][1]]
        if len(owners) > 1 or (pkg == "onnxruntime" and not owners):
            want = "exactly one" if pkg == "onnxruntime" else "at most one"
            names = "; ".join(label(k, found[k][0]) for k in owners) or "none"
            findings.append("the %s import package has %d owners (%s), expected %s" % (pkg, len(owners), names, want))
        findings.extend(import_findings(pkg, [found[k][0] for k in owners]))
    return findings


def check(store):
    """(findings, chain labels) for the environment against the chain wheel store."""
    index = store_index(store)
    findings, chain = [], []
    if not any(ORT_RUNTIME.match(name) for name, _ in index):
        findings.append("the chain wheel store %s holds no onnxruntime wheel" % store)
    found = candidates()
    for key in sorted(found):
        dist = found[key][0]
        wheel = index.get((key[0], header(dist, "Version")))
        if wheel is None:
            findings.append("%s is not a chain wheel: the store %s has no wheel of that name and version" % (label(key, dist), store))
            continue
        problems = compare(dist, wheel)
        findings.extend("%s: %s" % (label(key, dist), p) for p in problems)
        if not problems:
            chain.append("%s = %s" % (label(key, dist), os.path.basename(wheel)))
    findings.extend(owner_findings(found))
    return findings, chain


def main(argv=None):
    parser = argparse.ArgumentParser(description="ONNX Runtime census of this interpreter's environment")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="fail unless every ORT distribution is a chain wheel")
    mode.add_argument("--purge-list", action="store_true", help="print the ORT distributions to uninstall")
    parser.add_argument("--store", default="", help="the chain wheel store")
    args = parser.parse_args(argv)
    if args.purge_list:
        for name in sorted({key[0] for key in candidates() if key[0]}):
            print("ORT-CENSUS PURGE %s" % name)
        return 0
    try:
        findings, chain = check(args.store)
    except Exception as exc:  # an unreadable environment is a failure, never a pass
        findings, chain = ["the census could not complete: %s: %s" % (type(exc).__name__, exc)], []
    for line in chain:
        print("ORT-CENSUS chain %s" % line)
    for finding in findings:
        print("ORT-CENSUS FAIL %s" % finding)
    if findings:
        print("ORT-CENSUS FAILED: %d finding(s)" % len(findings))
        return 1
    print("ORT-CENSUS PASS: %d chain distribution(s) from %s" % (len(chain), args.store))
    return 0


if __name__ == "__main__":
    sys.exit(main())
