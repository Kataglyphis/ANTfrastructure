#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""The free-threaded wheel: does a project declare support, and does its installed wheel keep the GIL off.

`declares PYPROJECT` runs on any 3.11+; `prove DIST` runs as `python -I` in the venv holding the wheel.
Exit 0 yes, 1 no, 2 cannot tell. See docs/python-ci.md#two-wheels-gil-and-free-threaded
"""

import argparse
import importlib.machinery
import importlib.metadata
import importlib.util
import re
import sys
import sysconfig
import warnings
from pathlib import Path

CLASSIFIER = "Programming Language :: Python :: Free Threading"
GIL_WARNING = re.compile(r"enabled to load module '([^']+)'")
# Suffixes that carry no interpreter tag, which a plain shared library has too (ORT's libonnxruntime_providers_shared.so).
BARE_SUFFIXES = (".so", ".pyd")


def declares(pyproject: str) -> int:
    """Print the project's Free Threading classifier and return 0, or why there is none and return 1."""
    import tomllib  # noqa: PLC0415 -- prove runs on interpreters this import need not exist on

    path = Path(pyproject)
    if not path.is_file():
        print(f"no {path}")
        return 1
    try:
        with path.open("rb") as fh:
            project = tomllib.load(fh).get("project", {})
    except tomllib.TOMLDecodeError as exc:
        print(f"{path} is not valid TOML: {exc}")
        return 2
    classifiers = project.get("classifiers", [])
    hits = [c for c in classifiers if c == CLASSIFIER or c.startswith(CLASSIFIER + " :: ")]
    if hits:
        print(hits[0])
        return 0
    if "classifiers" in project.get("dynamic", []):
        print(f"{path} leaves its classifiers dynamic")
    else:
        print(f"no '{CLASSIFIER}' classifier in {path}")
    return 1


def exports_init(path: str, name: str) -> bool:
    """Whether a bare .so/.pyd defines PyInit_<its module name>; a library a wheel bundles beside its modules does not."""
    symbol = b"PyInit_" + name.removesuffix(".__init__").rsplit(".", 1)[-1].encode() + b"\0"
    try:
        return symbol in Path(path).read_bytes()
    except OSError:
        return True


def extension_modules(dist: str) -> list[tuple[str, str]]:
    """(dotted name, file) of every compiled module the installed distribution owns."""
    suffixes = sorted(importlib.machinery.EXTENSION_SUFFIXES, key=len, reverse=True)
    found = []
    for item in importlib.metadata.distribution(dist).files or ():
        rel = str(item).replace("\\", "/")
        suffix = next((s for s in suffixes if rel.endswith(s)), None)
        if suffix and not rel.startswith("../"):
            name = rel[: -len(suffix)].replace("/", ".")
            if suffix in BARE_SUFFIXES and not exports_init(str(item.locate()), name):
                continue
            # A compiled pkg/__init__ exports PyInit_pkg: it loads under the package's name.
            found.append((name.removesuffix(".__init__"), str(item.locate())))
    return sorted(found)


def load_all(modules: list[tuple[str, str]]) -> tuple[list[str], list[str]]:
    """Create each module without running its body (CPython decides about the GIL there): GIL offenders, failures."""
    offenders, failures = [], []
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        for name, path in modules:
            try:
                spec = importlib.util.spec_from_file_location(name, path)
                importlib.util.module_from_spec(spec)
            except Exception as exc:  # noqa: BLE001 -- every failure is reported, none may stop the census
                failures.append(f"{name}: {exc}")
    for w in caught:
        m = GIL_WARNING.search(str(w.message))
        if m:
            offenders.append(m.group(1))
    return offenders, failures


def prove(dist: str) -> int:
    """Return 0 when every compiled module of the distribution loads with the GIL still disabled."""
    if not sysconfig.get_config_var("Py_GIL_DISABLED"):
        print(f"ERROR: {sys.executable} is not a free-threaded interpreter", file=sys.stderr)
        return 2
    if sys._is_gil_enabled():  # noqa: SLF001 -- the documented free-threading probe
        print("ERROR: the GIL is enabled before any import (-X gil=1?)", file=sys.stderr)
        return 2
    try:
        modules = extension_modules(dist)
    except importlib.metadata.PackageNotFoundError:
        print(f"ERROR: {dist} is not installed in {sys.prefix}", file=sys.stderr)
        return 2
    if not modules:
        print(f"ERROR: {dist} owns no compiled module, so its wheel is no binary build", file=sys.stderr)
        return 2
    offenders, failures = load_all(modules)
    for failure in failures:
        print(f"ERROR: cannot load {failure}", file=sys.stderr)
    if sys._is_gil_enabled() or offenders:  # noqa: SLF001
        # CPython warns once: modules loaded after the first offender find the GIL on already.
        first = offenders[0] if offenders else "an unnamed module"
        print(f"ERROR: the GIL was re-enabled, first by {first}; Cython needs freethreading_compatible=True", file=sys.stderr)
        return 1
    if failures:
        return 1
    version = ".".join(map(str, sys.version_info[:3]))
    print(f"{len(modules)} compiled module(s) of {dist} loaded on free-threaded {version}; the GIL stayed disabled")
    return 0


def main(argv: list[str]) -> int:
    """Dispatch the two subcommands."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("declares").add_argument("pyproject")
    sub.add_parser("prove").add_argument("distribution")
    args = parser.parse_args(argv)
    if args.command == "declares":
        return declares(args.pyproject)
    return prove(args.distribution)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
