#!/usr/bin/env python3
"""Stage the image's shared CPython as a movable tree, and prove a moved copy runs; docs/python-app-bundles.md#the-relocated-image-cpython."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Callable, Iterable
from pathlib import Path
from typing import NoReturn

MARKER = "_KATAGLYPHIS_BUILD_PREFIX"
PC_PREFIX = "prefix=${pcfiledir}/../.."
RUNPATH = "$ORIGIN/../lib"

FACTS_PROBE = """
import importlib, json, sys, sysconfig
v = sysconfig.get_config_vars()
name = sysconfig._get_sysconfigdata_name()
print(json.dumps({
    "base_prefix": sys.base_prefix,
    "version": v.get("VERSION") or "",
    "ldversion": v.get("LDVERSION") or "",
    "shared": int(v.get("Py_ENABLE_SHARED") or 0),
    "instsoname": v.get("INSTSONAME") or "",
    "sysconfigdata": name,
    "sysconfigdata_file": importlib.import_module(name).__file__,
    "build_prefix": importlib.import_module(name).build_time_vars["prefix"],
}))
"""

MOVED_PROBE = """
import ctypes, json, os, sqlite3, ssl, sys, sysconfig, zlib
maps = [line.split()[-1] for line in open("/proc/self/maps") if "libpython" in line]
print(json.dumps({
    "prefix": sys.prefix,
    "base_prefix": sys.base_prefix,
    "os_file": os.__file__,
    "libpython": sorted(set(maps)),
    "vars": {k: v for k, v in sysconfig.get_config_vars().items() if isinstance(v, str)},
}))
"""

RELOCATION_BLOCK = """

# Appended by python-relocate.py: the build prefix becomes wherever this tree now sits.
import re as _re
import sys as _sys

{marker} = {build_prefix!r}
_PREFIX_TOKEN = _re.compile(r"(?:^|(?<=[\\s'\\"=:,])|(?<=-[ILR]))" + _re.escape({marker}) + r"(?=/|$|[\\s'\\":,])")
build_time_vars = {{
    _key: _PREFIX_TOKEN.sub(lambda _m: _sys.base_prefix, _value) if isinstance(_value, str) else _value
    for _key, _value in build_time_vars.items()
}}
"""


def fail(message: str) -> NoReturn:
    """Print the failure and exit nonzero."""
    print(f"FAIL: {message}")
    sys.exit(1)


def query_facts(python: str) -> dict[str, object]:
    """Ask the source interpreter for the facts its layout depends on."""
    out = subprocess.run(
        [python, "-I", "-c", FACTS_PROBE], check=True, capture_output=True, text=True
    ).stdout
    facts: dict[str, object] = json.loads(out)
    return facts


def stdlib_ignore(stdlib: Path) -> Callable[[str, list[str]], Iterable[str]]:
    """Leave out the system site-packages, the static libpython and the GPL-3 readline binding."""

    def ignore(directory: str, names: list[str]) -> Iterable[str]:
        here = Path(directory)
        if here == stdlib / "site-packages":
            return [n for n in names if n != "README.txt"]
        if here == stdlib / "lib-dynload":
            # A shipped bundle must not link GNU readline (GPL-3); its launchers never start a REPL.
            return [n for n in names if n.startswith("readline.")]
        return [n for n in names if n.startswith("libpython") and n.endswith(".a")]

    return ignore


def copy_tree(prefix: Path, dest: Path, facts: dict[str, object]) -> Path:
    """Copy one interpreter's files from prefix into dest; returns the staged executable."""
    ver, ldver = str(facts["version"]), str(facts["ldversion"])
    stdlib = prefix / "lib" / f"python{ldver}"
    if not stdlib.is_dir():
        stdlib = prefix / "lib" / f"python{ver}"
    exe = prefix / "bin" / f"python{ldver}"
    for required in (exe, stdlib, prefix / "lib" / str(facts["instsoname"])):
        if not required.exists():
            fail(
                f"{required} is missing; the source prefix is not a complete CPython install"
            )
    (dest / "bin").mkdir(parents=True)
    (dest / "lib").mkdir()
    shutil.copy2(exe.resolve(), dest / "bin" / exe.name)
    config = prefix / "bin" / f"python{ldver}-config"
    if config.is_file():
        shutil.copy2(config, dest / "bin" / config.name)
        (dest / "bin" / "python3-config").symlink_to(config.name)
    for alias in ("python3", "python"):
        (dest / "bin" / alias).symlink_to(exe.name)
    for lib in sorted((prefix / "lib").glob(f"libpython{ldver}.so*")) + sorted(
        (prefix / "lib").glob("libpython3.so")
    ):
        shutil.copy2(lib, dest / "lib" / lib.name, follow_symlinks=False)
    shutil.copytree(
        stdlib,
        dest / "lib" / stdlib.name,
        symlinks=True,
        ignore=stdlib_ignore(stdlib),
    )
    include = prefix / "include" / f"python{ldver}"
    if include.is_dir():
        shutil.copytree(include, dest / "include" / include.name, symlinks=True)
    for pc in sorted((prefix / "lib" / "pkgconfig").glob(f"python-{ver}*.pc")):
        (dest / "lib" / "pkgconfig").mkdir(exist_ok=True)
        shutil.copy2(pc, dest / "lib" / "pkgconfig" / pc.name)
    return dest / "bin" / exe.name


def relocate_sysconfigdata(module: Path, build_prefix: str) -> None:
    """Append the runtime prefix rewrite and drop the stale caches beside it."""
    if not module.is_file():
        fail(f"{module} is missing; sysconfig would fall back to the build prefix")
    text = module.read_text(encoding="utf-8")
    if MARKER in text:
        fail(f"{module} is already relocated")
    module.write_text(
        text + RELOCATION_BLOCK.format(marker=MARKER, build_prefix=build_prefix),
        encoding="utf-8",
    )
    for stale in [
        *module.parent.glob(f"__pycache__/{module.stem}.*.pyc"),
        *module.parent.glob("_sysconfig_vars_*.json"),
    ]:
        stale.unlink()


def relocate_pkgconfig(dest: Path) -> None:
    """Point each python .pc file's prefix at its own location."""
    for pc in sorted((dest / "lib" / "pkgconfig").glob("*.pc")):
        lines = pc.read_text(encoding="utf-8").splitlines(keepends=True)
        pc.write_text(
            "".join(
                PC_PREFIX + "\n" if line.startswith("prefix=") else line
                for line in lines
            ),
            encoding="utf-8",
        )


def stage(args: argparse.Namespace) -> None:
    """Stage --python's install into --dest."""
    facts = query_facts(args.python)
    prefix = Path(str(facts["base_prefix"])).resolve()
    if not facts["shared"]:
        fail(
            f"{args.python} is not a --enable-shared build; its interpreter cannot load a moved libpython"
        )
    if prefix in (Path("/"), Path("/usr")):
        fail(
            f"{args.python} is the distribution's interpreter ({prefix}), not the image's source build"
        )
    dest = Path(args.dest)
    if dest.exists():
        fail(f"{dest} exists; stage into a fresh directory")
    data = Path(str(facts["sysconfigdata_file"])).resolve()
    if not data.is_relative_to(prefix):
        fail(f"{data} lies outside {prefix}; the staged tree would not carry it")
    exe = copy_tree(prefix, dest, facts)
    subprocess.run([args.patchelf, "--set-rpath", RUNPATH, str(exe)], check=True)
    # Cross-built trees keep it in lib-dynload, native ones beside the stdlib.
    module = dest / data.relative_to(prefix)
    relocate_sysconfigdata(module, str(facts["build_prefix"]))
    relocate_pkgconfig(dest)
    subprocess.run([str(exe), "-I", "-m", "py_compile", str(module)], check=True)
    print(
        f"OK: staged {prefix} as a relocatable CPython {facts['ldversion']} in {dest}"
    )


def dynamic_section(readelf: str, path: Path) -> tuple[list[str], list[str]] | None:
    """An ELF file's RUNPATH/RPATH entries and NEEDED sonames, or None when readelf rejects it."""
    done = subprocess.run(
        [readelf, "-d", str(path)], capture_output=True, text=True, check=False
    )
    if done.returncode != 0:
        return None
    entries: list[str] = []
    for found in re.findall(
        r"\((?:RUNPATH|RPATH)\)\s+Library r(?:un)?path: \[([^\]]*)\]", done.stdout
    ):
        entries.extend(e for e in found.split(":") if e)
    needed = re.findall(r"\(NEEDED\)\s+Shared library: \[([^\]]*)\]", done.stdout)
    return entries, needed


def is_elf(path: Path) -> bool:
    """True for a regular file that starts with the ELF magic."""
    if path.is_symlink() or not path.is_file():
        return False
    with path.open("rb") as stream:
        return stream.read(4) == b"\x7fELF"


def elf_findings(tree: Path, exe: Path, readelf: str) -> list[str]:
    """Every absolute or missing RUNPATH, unreadable ELF and GPL-3 readline link in the tree."""
    findings: list[str] = []
    exe_section = dynamic_section(readelf, exe)
    if exe_section is None or RUNPATH not in exe_section[0]:
        findings.append(f"{exe.name} has no RUNPATH {RUNPATH} (readelf: {exe_section})")
    for path in sorted(p for p in tree.rglob("*") if is_elf(p)):
        rel = path.relative_to(tree)
        section = dynamic_section(readelf, path)
        if section is None:
            findings.append(f"readelf cannot read {rel}")
            continue
        findings += [
            f"{rel} has an absolute RUNPATH entry {e}"
            for e in section[0]
            if not e.startswith("$ORIGIN")
        ]
        findings += [
            f"{rel} links {n} (GPL-3)"
            for n in section[1]
            if n.startswith("libreadline")
        ]
    return findings


def build_prefix_of(stdlib: Path) -> str:
    """The build prefix stage recorded in the relocated sysconfigdata."""
    for module in sorted(
        [
            *stdlib.glob("_sysconfigdata_*.py"),
            *stdlib.glob("lib-dynload/_sysconfigdata_*.py"),
        ]
    ):
        found = re.search(
            rf"^{MARKER} = '([^']+)'$", module.read_text(encoding="utf-8"), re.MULTILINE
        )
        if found:
            return found.group(1)
    fail(f"no relocated _sysconfigdata under {stdlib}; run stage first")


def prefix_token(prefix: str) -> re.Pattern[str]:
    """Matches prefix as a whole path component, so /usr/localfoo is no finding."""
    return re.compile(re.escape(prefix) + r"(?=/|$|[\s'\":,])")


def moved_findings(
    report: dict[str, object], moved: Path, forbidden: list[str]
) -> list[str]:
    """What the moved interpreter still reads from the build prefix or the unmoved tree."""
    findings: list[str] = []
    for key in ("prefix", "base_prefix"):
        if Path(str(report[key])).resolve() != moved:
            findings.append(f"sys.{key} is {report[key]}, not the moved {moved}")
    if not str(report["os_file"]).startswith(f"{moved}/"):
        findings.append(f"the stdlib loads from {report['os_file']}, outside {moved}")
    libs = report["libpython"] if isinstance(report["libpython"], list) else []
    if not libs or any(not str(lib).startswith(f"{moved}/") for lib in libs):
        findings.append(f"libpython is mapped from {libs}, not from {moved}/lib")
    variables = report["vars"] if isinstance(report["vars"], dict) else {}
    patterns = [prefix_token(p) for p in forbidden]
    for key, value in sorted(variables.items()):
        if any(p.search(str(value)) for p in patterns):
            findings.append(f"sysconfig {key} = {value} names {' or '.join(forbidden)}")
    return findings


def check(args: argparse.Namespace) -> None:
    """Move a copy of --tree to a fresh directory and fail on anything still tied to the old place."""
    tree = Path(args.tree).resolve()
    stdlib = next((p for p in (tree / "lib").glob("python3*") if p.is_dir()), None)
    if stdlib is None:
        fail(f"{tree}/lib holds no python3* stdlib")
    forbidden = [build_prefix_of(stdlib), str(tree)]
    with tempfile.TemporaryDirectory(prefix="python-relocate-") as scratch:
        moved = Path(scratch).resolve() / "moved"
        shutil.copytree(tree, moved, symlinks=True)
        exe = moved / "bin" / "python3"
        env = {
            k: v
            for k, v in os.environ.items()
            if not k.startswith(("PYTHON", "LD_LIBRARY_PATH"))
        }
        done = subprocess.run(
            [str(exe), "-I", "-c", MOVED_PROBE],
            capture_output=True,
            text=True,
            env=env,
            check=False,
            cwd=scratch,
        )
        if done.returncode != 0:
            fail(
                f"the moved interpreter did not run (rc {done.returncode}): {done.stderr.strip()[-400:]}"
            )
        findings = moved_findings(json.loads(done.stdout), moved, forbidden)
        findings += elf_findings(moved, exe.resolve(), args.readelf)
    for finding in findings:
        print(f"FAIL: {finding}")
    if findings:
        sys.exit(1)
    print(
        f"OK: a moved copy of {tree} runs from its new place (ssl, sqlite3, ctypes, zlib import)"
    )


def main() -> None:
    """Dispatch the two subcommands."""
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    staging = sub.add_parser(
        "stage", help="copy an installed shared CPython into a relocatable tree"
    )
    staging.add_argument("--python", required=True)
    staging.add_argument("--dest", required=True)
    staging.add_argument(
        "--patchelf", default=os.environ.get("KATAGLYPHIS_PATCHELF", "patchelf")
    )
    checking = sub.add_parser("check", help="prove a moved copy of a staged tree runs")
    checking.add_argument("--tree", required=True)
    checking.add_argument("--readelf", default="readelf")
    args = parser.parse_args()
    if args.command == "stage":
        stage(args)
    else:
        check(args)


if __name__ == "__main__":
    main()
