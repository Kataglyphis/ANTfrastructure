#!/usr/bin/env python3
"""Freeze bounded MIGraphX preparation or selected dependency builds; no full backend or image acceptance."""

import argparse
import hashlib
import json
import re
import runpy
import shlex
import shutil
import subprocess
import uuid
from pathlib import Path

from host_commands import checked_output, run_logged
from owned_containers import OwnedContainers

ROOT = Path(__file__).resolve().parents[2]
LABEL = "org.kataglyphis.migraphx-configure"
ARCHIVES = {
    "parsers": (("archive", "abseil.tar.gz"), ("protobuf_archive", "protobuf.tar.gz")),
    "configure": (("archive", "source.tar.gz"), ("rocm_cmake_archive", "rocm-cmake.tar.gz"),
                  ("msgpack_archive", "msgpack.tar.gz")),
    "ck": (("archive", "source.tar.gz"), ("rocm_cmake_archive", "rocm-cmake.tar.gz")),
    "rocmlir-build": (("archive", "source.tar.gz"), ("rocm_cmake_archive", "rocm-cmake.tar.gz")),
    "rocmlir": (("archive", "source.tar.gz"), ("rocm_cmake_archive", "rocm-cmake.tar.gz")),
    "sdk": (),
    "ck-consumer": (),
    "rocmlir-consumer": (),
    "python-consumer": (),
}
BUILD_PROFILES = {"parsers": (3600, "2", "6g"), "rocmlir-build": (7200, "4", "12g")}
PREFIX_INPUTS = (("deps_prefix", "/deps-prefix", True), ("original_header", "/ck-original-header.hpp", False),
                 ("original_source", "/rocmlir-original-source", True))
INPUT_MODES = {
    "deps_prefix": (("ck-consumer", "sdk", "rocmlir-consumer"), ("ck-consumer", "rocmlir-consumer")),
    "original_header": (("ck-consumer",), ("ck-consumer",)),
    "original_source": (("rocmlir-consumer", "python-consumer"), ("rocmlir-consumer", "python-consumer")),
}


def validate_prefix_inputs(args: argparse.Namespace, parser: argparse.ArgumentParser) -> None:
    for name, _target, directory in PREFIX_INPUTS:
        value = getattr(args, name)
        allowed, required = INPUT_MODES[name]
        if value is None:
            if args.mode in required:
                parser.error("selected consumer requires " + name.replace("_", "-"))
            continue
        if args.mode not in allowed:
            parser.error(name.replace("_", "-") + " is not used by this mode")
        try:
            value = value.resolve(strict=True)
        except OSError as error:
            parser.error(str(error))
        if not (value.is_dir() if directory else value.is_file()):
            parser.error(name.replace("_", "-") + " has the wrong filesystem type")
        setattr(args, name, value)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--mode", choices=("configure", "sdk", "ck", "ck-consumer", "rocmlir", "rocmlir-consumer", "python-consumer", "parsers", "rocmlir-build"), default="configure")
    parser.add_argument("--archive", type=Path, help="required in configure/ck/rocmlir/rocmlir-build/parsers modes")
    parser.add_argument("--protobuf-archive", type=Path, help="required in parsers mode")
    parser.add_argument("--rocm-cmake-archive", type=Path, help="required in configure/ck/rocmlir/rocmlir-build modes")
    parser.add_argument("--msgpack-archive", type=Path, help="required in configure mode")
    parser.add_argument("--deps-prefix", type=Path, help="supplied development prefix for SDK or external consumer mode")
    parser.add_argument("--original-header", type=Path, help="original ck/utility/type.hpp for CK consumer mode")
    parser.add_argument("--original-source", type=Path, help="original source tree for the selected external consumer")
    parser.add_argument("--compiler-cache", required=True, type=Path)
    parser.add_argument("--unit", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--engine", default="nerdctl")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*\.service", args.unit):
        parser.error("unit must be a plain explicit .service name")
    args.output = args.output.resolve()
    validate_prefix_inputs(args, parser)
    archives = [name for name, _target in ARCHIVES[args.mode]]
    for name in archives:
        value = getattr(args, name)
        if value is None:
            parser.error("selected mode requires archive: " + name)
        setattr(args, name, value.resolve(strict=True))
    args.compiler_cache = args.compiler_cache.resolve(strict=True)
    if not all(getattr(args, name).is_file() for name in archives) or not args.compiler_cache.is_dir():
        parser.error("archive must be a file and compiler-cache an existing directory")
    return args


def payload(args: argparse.Namespace, source: Path, run_id: str) -> list[str]:
    _timeout, cpus, memory = BUILD_PROFILES.get(args.mode, (300, "2", "6g"))
    archives = []
    for name, target in ARCHIVES[args.mode]:
        archives += ["-v", f"{getattr(args, name)}:/{target}:ro"]
    for name, target, _directory in PREFIX_INPUTS:
        value = getattr(args, name)
        if value is not None:
            if name == "original_source" and args.mode == "python-consumer":
                target = "/migraphx-original-source"
            archives += ["-v", f"{value}:{target}:ro"]
    if args.deps_prefix is not None:
        archives += ["--env", "MIGRAPHX_DEPS_PREFIX=/deps-prefix"]
    return [
        args.engine, "run", "--name", args.unit.removesuffix(".service"),
        "--cidfile", str(args.output / "container.cid"), "--label", f"{LABEL}={run_id}",
        "--pull", "never", "--init", "--security-opt", "apparmor=unconfined",
        "--user", "0:0", "--cpus", cpus, "--memory", memory, "--network", "none",
        "--workdir", "/hub", "-v", f"{source}:/hub:ro",
        "-v", f"{source / 'linux/scripts/01-core'}:/opt/scripts/core:ro",
        "-v", f"{args.output}:/proof", *archives,
        "-v", f"{args.compiler_cache}:/cache", args.image, "/bin/bash",
        "/hub/linux/scripts/03-media/build/migraphx/configure-proof.sh",
        *([args.mode] if args.mode != "configure" else []),
    ]


def unit_command(args: argparse.Namespace, source: Path, run_id: str) -> list[str]:
    timeout, _cpus, _memory = BUILD_PROFILES.get(args.mode, (300, "2", "6g"))
    cleanup = [
        "/usr/bin/python3", str(source / "linux/scripts/cleanup-owned-containers.py"),
        "--engine", args.engine, "--owner-label", LABEL, "--run-id", run_id,
        "--cidfile", str(args.output / "container.cid"), "--output", str(args.output / "cleanup.json"),
    ]
    return [
        "systemd-run", "--user", "--no-block", "--expand-environment=no", "--unit=" + args.unit,
        "-p", "Type=oneshot", "-p", "RemainAfterExit=yes", "-p", f"TimeoutStartSec={timeout}",
        "-p", "TimeoutStopSec=180", "-p", "StandardOutput=append:" + str(args.output / "unit.log"),
        "-p", "StandardError=append:" + str(args.output / "unit.log"),
        "-p", "ExecStopPost=" + shlex.join(cleanup), *payload(args, source, run_id),
    ]


def freeze_owner_source(output: Path) -> tuple[Path, str, bytes]:
    freeze = runpy.run_path(str(ROOT / "linux/scripts/run-isolated-preflight.py"))["freeze_source"]
    source, head = freeze("HEAD", output)
    patch = subprocess.check_output(["git", "-C", str(ROOT), "diff", "--cached", "--full-index", "--binary"])
    patch_file = output / "owner.patch"
    patch_file.write_bytes(patch)
    subprocess.run(["git", "-C", str(source), "apply", "--index", str(patch_file)], check=True, timeout=60)
    return source, head, patch


def require_build_disk(path: Path) -> dict[str, int | bool]:
    free = shutil.disk_usage(path).free
    canonical = checked_output([
        "bash", "-euo", "pipefail", "-c", 'source "$1"; _disk_guard_free_gb "$2"',
        "migraphx-vendor-disk", str(ROOT / "linux/scripts/01-core/disk-guard.sh"), str(path),
    ]).strip()
    if not canonical.isdecimal() or int(canonical) < 180 or free < 193273528320:
        raise ValueError("Vendor build requires the normal 180GiB reserve; no reclaim or override is performed")
    return {"available_bytes": free, "canonical_free_gib": int(canonical),
            "required_bytes": 193273528320, "reclaim_performed": False}


def main() -> int:
    args = arguments()
    state = checked_output(["systemctl", "--user", "show", "--property=LoadState", "--value", args.unit]).strip()
    if state != "not-found":
        raise ValueError("preserve the existing unit and choose a new unit name")
    admission = require_build_disk(args.output.parent) if args.mode in BUILD_PROFILES else None
    source, head, patch = freeze_owner_source(args.output)
    ownership = OwnedContainers(args.engine, LABEL, uuid.uuid4().hex)
    command = unit_command(args, source, ownership.run_id)
    data = {
        "unit": args.unit, "run_id": ownership.run_id, "owner_label": LABEL, "command": command,
        "source": str(source), "head": head, "patch_sha256": hashlib.sha256(patch).hexdigest(),
        "mode": args.mode, "resource_admission": admission, "dependency_prefix": str(args.deps_prefix) if args.deps_prefix else None,
        "original_header": str(args.original_header) if args.original_header else None,
        "original_source": str(args.original_source) if args.original_source else None, "scope": __doc__,
    }
    (args.output / "invocation.json").write_text(json.dumps(data, indent=2) + "\n")
    return run_logged(command, args.output / "launch.log")


if __name__ == "__main__":
    raise SystemExit(main())
