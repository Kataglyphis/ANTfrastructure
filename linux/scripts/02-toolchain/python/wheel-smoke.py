#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Import an installed wheel's package and load every compiled module it owns, from the venv and not a source tree.

Runs as `python -I wheel-smoke.py DIST PACKAGE [--require-compiled]` in the venv holding the wheel.
Exit 0 yes, 1 no, 2 cannot tell. See docs/python-ci.md#riscv64-the-image-itself-runs-under-qemu
"""

import argparse
import importlib
import importlib.metadata
import importlib.util
import platform
import sys
from pathlib import Path


def load_sibling(stem: str):
    """The free-threaded helper beside this file, by path: -I keeps the script's directory off sys.path."""
    path = Path(__file__).with_name(f"{stem}.py")
    spec = importlib.util.spec_from_file_location(stem.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def inside(path: str, root: Path) -> bool:
    """Whether path resolves under root."""
    try:
        Path(path).resolve().relative_to(root)
    except ValueError:
        return False
    return True


def smoke(dist: str, package: str, require_compiled: bool) -> int:
    """Return 0 when the package imports from this venv and every compiled module of the distribution loads."""
    prefix = Path(sys.prefix).resolve()
    ftw = load_sibling("free-threaded-wheel")
    try:
        modules = ftw.extension_modules(dist)
    except importlib.metadata.PackageNotFoundError:
        print(f"ERROR: {dist} is not installed in {prefix}", file=sys.stderr)
        return 2
    if require_compiled and not modules:
        print(f"ERROR: {dist} owns no compiled module, so its wheel is no binary build", file=sys.stderr)
        return 2
    failures = [f"{path}: installed outside {prefix}" for _, path in modules if not inside(path, prefix)]
    # Loaded, not executed: a module body may import an optional extra the core install lacks.
    failures += ftw.load_all(modules)[1]
    try:
        where = getattr(importlib.import_module(package), "__file__", None) or ""
    except Exception as exc:  # noqa: BLE001 -- the import error is the verdict
        failures.append(f"import {package}: {type(exc).__name__}: {exc}")
    else:
        if not inside(where, prefix):
            failures.append(f"import {package}: came from {where or 'nowhere'}, not from {prefix}")
    for failure in failures:
        print(f"ERROR: {failure}", file=sys.stderr)
    if failures:
        return 1
    print(f"import {package} and {len(modules)} compiled module(s) of {dist} load on "
          f"{platform.machine()} CPython {platform.python_version()} from {prefix}")
    return 0


def main(argv: list[str]) -> int:
    """Parse the arguments and run the smoke."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("distribution")
    parser.add_argument("package")
    parser.add_argument("--require-compiled", action="store_true")
    args = parser.parse_args(argv)
    return smoke(args.distribution, args.package, args.require_compiled)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
