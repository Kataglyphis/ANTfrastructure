#!/usr/bin/env python3
"""Bind offline FT probe NumPy to pinned sources; this proves no ORT factory, GPU or inference."""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
import re
import shutil
import struct
import subprocess
import sys
import sysconfig
import tempfile
import zipfile
from email.parser import BytesParser
from pathlib import Path

LOCK = Path(__file__).with_suffix(".json")
MACHINES = {"amd64": ("x86_64", 62), "arm64": ("aarch64", 183), "riscv64": ("riscv64", 243)}


def target() -> tuple[str, str]:
    """A target interpreter must run here; host tags cannot stand in for a cross target."""
    if sysconfig.get_config_var("Py_GIL_DISABLED") != 1 or sys._is_gil_enabled():
        raise ValueError("probe dependencies require a running free-threaded interpreter with GIL off")
    arch = next(key for key, (machine, _) in MACHINES.items() if machine == platform.machine())
    return arch, f"cp{sys.version_info.major}{sys.version_info.minor}"


def artifact(version: str, arch: str, python_tag: str) -> dict:
    """Pin changes require fresh official artifact hashes, including the source-only RISC-V lane."""
    lock = json.loads(LOCK.read_text())
    if (version, python_tag) != (lock["numpy_version"], lock["python_tag"]):
        raise ValueError("NumPy or Python pin drifted from the probe dependency lock")
    row = lock["artifacts"][arch]
    name = row["filename"]
    if (not re.fullmatch(r"numpy-[A-Za-z0-9_.-]+", name) or not re.fullmatch(r"[0-9a-f]{64}", row["sha256"])
            or not row["url"].startswith("https://files.pythonhosted.org/packages/")
            or row["url"].rsplit("/", 1)[-1] != name):
        raise ValueError("invalid pinned probe dependency artifact")
    return row


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def wheel_identity(path: Path, version: str, arch: str, python_tag: str) -> None:
    """Check metadata, carried license and ELF headers; this is not a complete ELF loader proof."""
    machine, elf_machine = MACHINES[arch]
    name, have_version, py, abi, plat = path.name.removesuffix(".whl").split("-")
    if (name, have_version, py, abi) != ("numpy", version, python_tag, python_tag + "t"):
        raise ValueError("NumPy wheel version or threading ABI differs")
    if any(not tag.endswith("_" + machine) for tag in plat.split(".")):
        raise ValueError("NumPy wheel architecture differs")
    with zipfile.ZipFile(path) as wheel:
        metadata = f"numpy-{version}.dist-info/METADATA"
        license_name = f"numpy-{version}.dist-info/licenses/LICENSE.txt"
        members = wheel.namelist()
        if len(set(members)) != len(members) or not wheel.read(license_name).strip():
            raise ValueError("NumPy wheel lacks unique members and original license")
        meta = BytesParser().parsebytes(wheel.read(metadata))
        if (meta["Name"], meta["Version"]) != ("numpy", version):
            raise ValueError("NumPy wheel metadata differs")
        verify_elf_headers(wheel, elf_machine)


def verify_elf_headers(wheel: zipfile.ZipFile, machine: int) -> None:
    binaries = 0
    for member in wheel.namelist():
        with wheel.open(member) as stream:
            header = stream.read(20)
        if header.startswith(b"\x7fELF"):
            if header[4:6] != b"\x02\x01" or len(header) < 20 or struct.unpack_from("<H", header, 18)[0] != machine:
                raise ValueError("NumPy wheel contains a foreign ELF")
            binaries += 1
    if not binaries:
        raise ValueError("NumPy wheel contains no native code")


def verify_pool(pool: Path, version: str, arch: str, python_tag: str) -> Path:
    if pool.is_symlink() or not pool.is_dir():
        raise ValueError("probe dependency pool is not a regular directory")
    row = artifact(version, arch, python_tag)
    record = json.loads((pool / "receipt.json").read_text())
    if (record["numpy_version"], record["arch"], record["python_tag"], record["artifact"]) != (version, arch, python_tag, row):
        raise ValueError("probe dependency receipt differs from pins or target")
    wheel_name = record["wheel"]
    if Path(wheel_name).name != wheel_name or not wheel_name.endswith(".whl"):
        raise ValueError("invalid probe dependency wheel basename")
    expected = {"receipt.json", row["filename"], wheel_name}
    if {p.name for p in pool.iterdir()} != expected or any(p.is_symlink() or not p.is_file() for p in pool.iterdir()):
        raise ValueError("probe dependency pool has unexpected entries")
    wheel = pool / wheel_name
    if digest(pool / row["filename"]) != row["sha256"] or digest(wheel) != record["wheel_sha256"]:
        raise ValueError("probe dependency bytes differ from recorded hashes")
    wheel_identity(wheel, version, arch, python_tag)
    return wheel


def install(wheel: Path, python: str) -> None:
    subprocess.run(["uv", "pip", "install", "--offline", "--no-index", "--no-deps", "--python", python, str(wheel)], check=True)


def prove_import(wheel: Path, version: str, work: Path) -> None:
    environment = work / "venv"
    subprocess.run(["uv", "venv", "--python", sys.executable, str(environment)], check=True)
    python = str(environment / "bin/python")
    install(wheel, python)
    subprocess.run([python, "-I", "-c", ("import sys; assert not sys._is_gil_enabled(); "
                    "import numpy; assert numpy.__version__ == sys.argv[1]; assert not sys._is_gil_enabled()"), version], check=True)


def populate(args: argparse.Namespace, pool: Path, arch: str, python_tag: str) -> None:
    row = artifact(args.numpy_version, arch, python_tag)
    pool.mkdir()
    archive = pool / row["filename"]
    download = 'set -euo pipefail; source "$1"; download_verified_cached "$2" "$3" "$4" "$5"'
    subprocess.run(["bash", "-c", download, "probe-deps", str(args.core / "downloads.sh"), row["url"],
                    row["sha256"], str(archive), str(args.cache / "archives")], check=True)
    if digest(archive) != row["sha256"]:
        raise ValueError("downloaded probe source differs before build")
    if not archive.name.endswith(".whl"):
        subprocess.run(["uv", "build", "--wheel", "--no-python-downloads", "--python", sys.executable,
                        "--out-dir", str(pool), str(archive)], check=True)
    wheels = list(pool.glob("*.whl"))
    if len(wheels) != 1:
        raise ValueError("probe dependency build must produce exactly one wheel")
    record = {"numpy_version": args.numpy_version, "arch": arch, "python_tag": python_tag, "artifact": row,
              "wheel": wheels[0].name, "wheel_sha256": digest(wheels[0])}
    (pool / "receipt.json").write_text(json.dumps(record, indent=2) + "\n")


def build(args: argparse.Namespace, arch: str, python_tag: str) -> None:
    if args.pool.exists() or args.pool.is_symlink():
        raise FileExistsError("refusing an existing probe dependency output")
    artifact(args.numpy_version, arch, python_tag)
    args.cache.mkdir(parents=True, exist_ok=True)
    cached = args.cache / f"numpy-{args.numpy_version}-{python_tag}t-{arch}"
    with tempfile.TemporaryDirectory(dir=args.cache) as temporary:
        work = Path(temporary)
        pool = cached if cached.exists() else work / "pool"
        if not cached.exists():
            populate(args, pool, arch, python_tag)
        wheel = verify_pool(pool, args.numpy_version, arch, python_tag)
        prove_import(wheel, args.numpy_version, work)
        if pool != cached:
            pool.rename(cached)
        shutil.copytree(cached, args.pool)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("build", "install", "verify"))
    parser.add_argument("--pool", type=Path, default=Path("/opt/ft-probe-deps"))
    parser.add_argument("--cache", type=Path, default=Path("/var/cache/ft-probe-deps"))
    parser.add_argument("--core", type=Path, default=Path("/opt/scripts/core"))
    parser.add_argument("--numpy-version", required=True)
    parser.add_argument("--arch", choices=tuple(MACHINES), required=True)
    return parser.parse_args()


def main() -> int:
    try:
        args = arguments()
        arch, python_tag = target()
        if arch != args.arch:
            raise ValueError("requested architecture differs from the running target")
        if args.action == "build":
            build(args, arch, python_tag)
        else:
            wheel = verify_pool(args.pool, args.numpy_version, arch, python_tag)
            if args.action == "install":
                install(wheel, sys.executable)
    except subprocess.CalledProcessError as error:
        return error.returncode if error.returncode > 0 else 128 - error.returncode
    except (OSError, ValueError, KeyError, TypeError, StopIteration, zipfile.BadZipFile) as error:
        print(f"FT-PROBE-DEPS FAIL: {error}", file=sys.stderr)
        return 1
    print("FT-PROBE-DEPS OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
