#!/usr/bin/env python3
"""Check installed amd64 compiler responses and defaults; no per-ELF ISA, other SDK tools or consumer acceptance proof."""
from __future__ import annotations

import argparse
import json
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

GNU = ("gcc", "g++", "cc", "c++")
LLVM = ("clang", "clang++")
DEFINES = ("AVX2", "FMA", "BMI2")


def command(binary: str, arguments: list[str]) -> dict:
    argv = [binary, *arguments]
    try:
        child = subprocess.run(argv, input="", capture_output=True, text=True, check=False, timeout=20)
        return {"argv": argv, "returncode": child.returncode, "timed_out": False,
                "stdout": child.stdout, "stderr": child.stderr}
    except subprocess.TimeoutExpired as error:
        streams = {key: value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value or ""
                   for key, value in (("stdout", error.stdout), ("stderr", error.stderr))}
        return {"argv": argv, "returncode": None, "timed_out": True, **streams}
    except OSError as error:
        return {"argv": argv, "returncode": 127, "timed_out": False, "stdout": "", "stderr": str(error)}


def collect(expected: dict[str, str]) -> dict:
    tools = {}
    for name in (*GNU, *LLVM):
        path = shutil.which(name)
        record: dict = {"binary": path, "resolved_binary": str(Path(path).resolve()) if path else None}
        if name in GNU:
            language = "c++" if name.endswith("++") else "c"
            record.update({"version": command(name, ["-dumpfullversion"]),
                           "machine": command(name, ["-dumpmachine"]),
                           "defaults": command(name, ["-Q", "--help=target"]),
                           "macros": command(name, ["-dM", "-E", "-x", language, "-"])})
        else:
            record["version"] = command(name, ["--version"])
        tools[name] = record
    return {"schema_version": 1, "expected": expected,
            "host": {"system": platform.system(), "machine": platform.machine()}, "tools": tools}


def output(result: dict) -> str:
    if (type(result.get("returncode")) is not int or result["returncode"] != 0
            or result.get("timed_out") is not False):
        raise ValueError("compiler child failed or timed out")
    stdout, stderr = result["stdout"], result["stderr"]
    if not isinstance(stdout, str) or not isinstance(stderr, str) or len(stdout) + len(stderr) > 2 * 1024 * 1024:
        raise ValueError("invalid or unbounded compiler response")
    return stdout.strip()


def gnu_facts(record: dict, expected: str) -> dict:
    version = output(record["version"])
    if version != expected:
        raise ValueError(f"GCC full version {version!r} differs from {expected}")
    machine = output(record["machine"])
    if not machine.startswith("x86_64-") or not machine.endswith("-linux-gnu"):
        raise ValueError("compiler does not target amd64 Linux")
    defaults = output(record["defaults"])
    facts: dict = {"version": version, "machine": machine}
    for option, wanted in (("march", "x86-64-v3"), ("mtune", "generic")):
        values = re.findall(rf"^\s*-{option}=\s+(\S+)\s*$", defaults, re.MULTILINE)
        if values != [wanted]:
            raise ValueError(f"compiler default {option} differs from {wanted}: {values}")
        facts[option] = values[0]
    macros = output(record["macros"])
    for name in DEFINES:
        if re.findall(rf"^#define __{name}__ (\S+)$", macros, re.MULTILINE) != ["1"]:
            raise ValueError(f"compiler default must define __{name}__ exactly once as 1")
    facts["v3_defines"] = list(DEFINES)
    return facts


def llvm_facts(record: dict, expected: str) -> dict[str, str]:
    banner = output(record["version"]).splitlines()
    match = re.search(r"\bclang version (\S+)", banner[0]) if banner else None
    if not match or match[1] != expected:
        raise ValueError(f"LLVM full version differs from {expected}")
    return {"version": match[1], "banner": banner[0]}


def validate(payload: dict, expected: dict[str, str]) -> dict:
    if type(payload.get("schema_version")) is not int or payload["schema_version"] != 1 or payload.get("expected") != expected:
        raise ValueError("compiler probe source expectations differ")
    if payload["host"]["system"] != "Linux" or payload["host"]["machine"] not in ("x86_64", "amd64"):
        raise ValueError("this compiler-default probe requires an amd64 Linux host")
    if set(payload["tools"]) != {*GNU, *LLVM}:
        raise ValueError("compiler probe must contain exactly every ordinary compiler alias")
    facts = {}
    for name in GNU:
        facts[name] = gnu_facts(payload["tools"][name], expected["gcc"])
    for name in LLVM:
        facts[name] = llvm_facts(payload["tools"][name], expected["llvm"])
    return facts


def pin(value: str) -> str:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value):
        raise argparse.ArgumentTypeError("a complete stable x.y.z pin is required")
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gcc-version", type=pin, required=True)
    parser.add_argument("--llvm-version", type=pin, required=True)
    args = parser.parse_args()
    expected = {"gcc": args.gcc_version, "llvm": args.llvm_version}
    payload = collect(expected)
    try:
        payload["facts"] = validate(payload, expected)
        payload["status"] = "passed-installed-amd64-compiler-defaults-only"
        status = 0
    except (ValueError, KeyError, TypeError) as error:
        payload["status"] = "failed"
        payload["error"] = str(error)
        status = 1
    print(json.dumps(payload, sort_keys=True))
    return status


if __name__ == "__main__":
    sys.exit(main())
