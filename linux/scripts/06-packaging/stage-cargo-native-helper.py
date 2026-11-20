#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Stage one exact Cargo helper; caller-owned JSON does not authenticate a build, linkage or runtime behavior."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import stat
import sys
import tempfile
from pathlib import Path
from typing import Any

from ort_census_probe import elf_target, file_sha

TARGETS = {"x86_64-unknown-linux-gnu": 62, "aarch64-unknown-linux-gnu": 183, "riscv64gc-unknown-linux-gnu": 243}


def messages(path: Path) -> list[dict[str, Any]]:
    result = []
    for line in path.read_text(encoding="utf-8").splitlines():
        row = json.loads(line)
        if not isinstance(row, dict) or not isinstance(row.get("reason"), str):
            raise TypeError("Invalid Cargo message")
        result.append(row)
    finished = [row for row in result if row["reason"] == "build-finished"]
    if len(finished) != 1 or result[-1] != finished[0] or finished[0].get("success") is not True:
        raise ValueError("Cargo messages do not end in one successful build")
    return result


def regular(path: Path, *, executable: bool) -> None:
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size < 64:
        raise ValueError(f"Missing, linked or empty native file: {path}")
    if executable and not metadata.st_mode & 0o111:
        raise ValueError(f"Native helper is not executable: {path}")


def one(rows: list[dict[str, Any]], label: str) -> dict[str, Any]:
    if len(rows) != 1:
        raise ValueError(f"Expected one {label}, found {len(rows)}")
    return rows[0]


def selected_helper(rows: list[dict[str, Any]], package: str, name_env: str, path_env: str) -> Path:
    row = one([r for r in rows if r["reason"] == "build-script-executed" and r.get("package_id") == package], "helper build script")
    pairs = row.get("env")
    if not isinstance(pairs, list) or any(not isinstance(p, list) or len(p) != 2 or not all(isinstance(v, str) for v in p) for p in pairs):
        raise ValueError("Invalid Cargo helper environment")
    values = dict(pairs)
    if len(values) != len(pairs):
        raise ValueError("Duplicate Cargo helper environment")
    name = values.get(name_env, "")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.+-]*", name) or name in (".", ".."):
        raise ValueError("Invalid native helper basename")
    out = Path(row.get("out_dir", ""))
    if not out.is_absolute() or out.resolve(strict=True) != out:
        raise ValueError("Cargo helper OUT_DIR must be canonical and absolute")
    helper = out / name
    if values.get(path_env) != str(helper):
        raise ValueError("Cargo helper path does not match its exact OUT_DIR and basename")
    return helper


def select_module(rows: list[dict[str, Any]], module: Path) -> None:
    matches = [r for r in rows if r["reason"] == "compiler-artifact" and str(module) in r.get("filenames", [])]
    row = one(matches, "selected native artifact")
    if row.get("profile", {}).get("test") is not False:
        raise ValueError("A test artifact cannot identify the packaged module")


def identity(path: Path, machine: int) -> None:
    with path.open("rb") as stream:
        header = stream.read(20)
    if elf_target(header) != (2, 1, machine) or int.from_bytes(header[16:18], "little") not in (2, 3):
        raise ValueError(f"Native ELF target or executable type differs: {path}")


def publish(helper: Path, destination: Path) -> None:
    expected = file_sha(str(helper))
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination, delete=False) as output:
            temporary = Path(output.name)
            with helper.open("rb") as source:
                shutil.copyfileobj(source, output)
            os.fchmod(output.fileno(), 0o755)
        if file_sha(str(temporary)) != expected or file_sha(str(helper)) != expected:
            raise ValueError("Native helper bytes changed during staging")
        os.link(temporary, destination / helper.name)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def run(args: argparse.Namespace) -> str:
    rows = messages(args.messages)
    module = args.module.absolute()
    regular(module, executable=False)
    select_module(rows, module)
    helper = selected_helper(rows, args.package_id, args.name_env, args.path_env)
    regular(helper, executable=True)
    for path in (module, helper):
        identity(path, TARGETS[args.target])
    destination = args.destination.absolute()
    if not stat.S_ISDIR(destination.lstat().st_mode) or destination.resolve(strict=True) != destination:
        raise ValueError("Native helper destination must be an existing canonical directory")
    publish(helper, destination)
    return helper.name


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("messages", "module", "destination"):
        parser.add_argument("--" + name, type=Path, required=True)
    for name in ("package-id", "name-env", "path-env"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--target", choices=TARGETS, required=True)
    try:
        print(run(parser.parse_args()))
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
