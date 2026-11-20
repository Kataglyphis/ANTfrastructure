#!/usr/bin/env python3
"""Inspect the selected Ninja plan and C/C++ cache bindings; no commands are built or binary linkage proved."""

import argparse
import collections
import hashlib
import json
import shlex
import subprocess
import sys
from pathlib import Path

CXX = {".cc", ".cpp", ".cxx", ".C", ".mm"}
TARGET = "librockCompiler"


def require(value: bool, message: str) -> None:
    if not value:
        raise ValueError(message)


def fingerprint(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()



def object_command(row: dict[str, str]) -> list[str] | None:
    args = shlex.split(row["command"])
    if Path(row["output"]).suffix == ".o":
        require("-c" in args, "Object rule has no compile command")
        return args
    source = Path(row["file"]).suffix
    compiler = any(Path(arg).name in {"clang", "clang++", "gcc", "g++", "cc", "c++"} for arg in args[:2])
    require(not ("-c" in args and (source in CXX | {".c", ".s", ".S"} or compiler)),
            "Unrecognized compiler output cannot be omitted from cache checks")
    return None

def compile_kind(row: dict[str, str], clang: str, gcc: str, launcher: str) -> str | None:
    args = object_command(row)
    if args is None:
        return None
    suffix = Path(row["file"]).suffix
    if suffix in {".s", ".S"}:
        require(args[0] == clang + "/bin/clang", "Assembly compiler differs from the selected source compiler")
        return "assembly"
    require(suffix == ".c" or suffix in CXX, "Unknown object source language")
    compiler = clang + ("/bin/clang" if suffix == ".c" else "/bin/clang++")
    require(args[:2] == [launcher, compiler], "C/C++ command lost its selected cache launcher or source compiler")
    require("--gcc-toolchain=" + gcc in args, "C/C++ command lost its selected GCC toolchain")
    return "c" if suffix == ".c" else "cxx"


def archive_members(rows: list[dict[str, str]]) -> list[str]:
    selected = [row for row in rows if row["output"].endswith("/rockCompiler.mri")]
    require(len(selected) == 1, "Expected one real fat-library MRI generator")
    args = shlex.split(selected[0]["command"])
    positions = [index for index in range(len(args) - 2) if args[index:index + 3] == ["for", "archive", "in"]]
    require(len(positions) == 1, "Unrecognized fat-library archive loop")
    start = positions[0] + 3
    end = args.index(";", start)
    members = args[start:end]
    require(bool(members) and len(set(members)) == len(members) and all(name.endswith(".a") for name in members),
            "Fat-library archive members are empty, repeated or not static archives")
    return members


def inspect_rows(data: object, clang: str, gcc: str, launcher: str) -> dict[str, object]:
    if not isinstance(data, list) or not data:
        raise ValueError("Empty or invalid Ninja compilation database")
    rows: list[dict[str, str]] = []
    for row in data:
        require(isinstance(row, dict) and all(isinstance(row.get(key), str) and row[key] for key in ("file", "command", "output")),
                "Incomplete Ninja command record")
        rows.append(row)
    counts: collections.Counter[str] = collections.Counter()
    assembly = []
    for row in rows:
        kind = compile_kind(row, clang, gcc, launcher)
        if kind:
            counts[kind] += 1
        if kind == "assembly":
            assembly.append(row["file"])
    require(counts["cxx"] > 0, "Selected target has no checked C++ compilations")
    return {"planned_commands": len(rows), "planned_compiles": dict(counts),
            "assembly_sources": assembly, "fat_archive_members": archive_members(rows)}


def run(args: argparse.Namespace) -> int:
    args.output.mkdir()
    inputs = ["CMakeCache.txt", "build.ninja", "CMakeFiles/rules.ninja"]
    before = {name: fingerprint(args.build / name) for name in inputs}
    for name, tool in [("compilation-database.json", "compdb-targets"), ("inputs.txt", "inputs"), ("commands.txt", "commands")]:
        with (args.output / name).open("x") as output, (args.output / (name + ".stderr")).open("x") as error:
            result = subprocess.run([args.ninja, "-C", str(args.build), "-t", tool, TARGET],
                                    stdout=output, stderr=error, check=False, timeout=30)
        if result.returncode:
            return result.returncode
    proof = inspect_rows(json.loads((args.output / "compilation-database.json").read_text()),
                         args.clang_prefix, args.gcc_prefix, args.cache_launcher)
    require(before == {name: fingerprint(args.build / name) for name in inputs}, "Ninja observation changed the configured inputs")
    proof.update(status="passed-build-plan-only", target=TARGET, configured_inputs_sha256=before,
                 compiler_prefix=args.clang_prefix, gcc_prefix=args.gcc_prefix, cache_launcher=args.cache_launcher,
                 scope=__doc__)
    (args.output / "proof.json").write_text(json.dumps(proof, indent=2) + "\n")
    print(json.dumps({key: proof[key] for key in ("status", "planned_commands", "planned_compiles")}))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("build", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    for name in ("clang-prefix", "gcc-prefix", "cache-launcher"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--ninja", default="ninja")
    args = parser.parse_args()
    try:
        return run(args)
    except (OSError, ValueError, TypeError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"rocMLIR build-plan refusal: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
