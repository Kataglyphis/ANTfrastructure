#!/usr/bin/env python3
"""Bind WASM modes, bytes and executed factory controls; no adapter, browser or inference proof."""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import runpy
import shutil
import sys
from pathlib import Path

RUNTIME = runpy.run_path(str(Path(__file__).with_name("ort-webgpu-wasm-runtime.py")))
BUILD = runpy.run_path(str(Path(__file__).with_name("ort-webgpu-build-proof.py")))
if not all(callable(BUILD.get(name)) for name in ("configured_mode", "write_receipt")):
    raise ValueError("missing canonical build-proof API")
RECEIPT = "ort-webgpu-wasm.json"
CACHE = "ort-wasm-cache.json"
FLAVORS = ("asyncify", "jspi")
PROBE_LICENSE = "ort-webgpu-factory-probe.LICENSE"


def expected_flags(flavor: str) -> dict[str, str]:
    return {"onnxruntime_USE_WEBGPU": "ON", "onnxruntime_USE_EP_API_ADAPTERS": "ON",
            "onnxruntime_WEBGPU_STATIC_PLUGIN": "ON", "onnxruntime_USE_EXTERNAL_DAWN": "OFF",
            "onnxruntime_ENABLE_WEBASSEMBLY_THREADS": "ON",
            "onnxruntime_ENABLE_WEBASSEMBLY_JSPI": "ON" if flavor == "jspi" else "OFF"}


def regular_prefix(prefix: Path) -> None:
    if prefix.is_symlink() or not prefix.is_dir():
        raise ValueError("WASM prefix is not a regular directory")


def file_digest(path: Path) -> str:
    if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= 1024 * 1024 * 1024:
        raise ValueError(f"invalid WASM artifact: {path}")
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def probe_license(prefix: Path) -> dict[str, str]:
    notice = prefix / PROBE_LICENSE
    digest = file_digest(notice)
    if digest != file_digest(Path(__file__).parent / "webgpu-factory-probe/LICENSE"):
        raise ValueError("WASM probe license differs from its original MIT text")
    return {"path": notice.name, "sha256": digest}


def stage_probe_license(prefix: Path) -> None:
    target = prefix / PROBE_LICENSE
    if target.exists() or target.is_symlink():
        probe_license(prefix)
        return
    shutil.copy2(Path(__file__).parent / "webgpu-factory-probe/LICENSE", target)
    probe_license(prefix)


def wasm_product(prefix: Path, flavor: str, install_notice: bool = False) -> dict:
    stem = f"ort-wasm-simd-threaded.{flavor}"
    wasm = prefix / (stem + ".wasm")
    digest = file_digest(wasm)
    with wasm.open("rb") as stream:
        if stream.read(8) != b"\0asm\x01\0\0\0":
            raise ValueError(f"not a WebAssembly v1 module: {wasm}")
    loader = prefix / (stem + ".mjs")
    loader_digest = file_digest(loader)
    if install_notice:
        stage_probe_license(prefix)
    return {"path": wasm.name, "sha256": digest,
            "loader": {"path": loader.name, "sha256": loader_digest}, "probe_license": probe_license(prefix)}


def source_identity(args: argparse.Namespace) -> dict:
    if not args.source_ref or not re.fullmatch(r"[0-9a-f]{40}", args.source_revision or ""):
        raise ValueError("WASM source ref and full Git revision are required")
    return {"ref": args.source_ref, "revision": args.source_revision}


def checked_receipt(args: argparse.Namespace, complete: bool) -> dict:
    regular_prefix(args.prefix)
    file_digest(args.prefix / RECEIPT)
    receipt = json.loads((args.prefix / RECEIPT).read_text())
    if (receipt.get("schema_version") != 2 or receipt.get("source") != source_identity(args)
            or receipt.get("config") != args.config):
        raise ValueError("WASM receipt source/configuration differs")
    phases = receipt["flavors"]
    if (not set(phases) <= set(FLAVORS)) or (complete and set(phases) != set(FLAVORS)):
        raise ValueError("WASM receipt lacks exactly both requested flavors")
    for flavor, phase in phases.items():
        if phase["configured_flags"] != expected_flags(flavor):
            raise ValueError("WASM receipt has a legacy or foreign configuration")
        if not re.fullmatch(r"[0-9a-f]{64}", phase["cmake_cache_sha256"]):
            raise ValueError("WASM receipt lacks its configured-cache identity")
        product = wasm_product(args.prefix, flavor)
        if phase["product"] != product:
            raise ValueError("compiled WASM bytes changed after their build proof")
        runtime_path = args.prefix / f"ort-webgpu-wasm.{flavor}.runtime.json"
        if phase["runtime"] != {"path": runtime_path.name, "sha256": file_digest(runtime_path)}:
            raise ValueError("WASM factory runtime receipt changed")
        RUNTIME["validate"](json.loads(runtime_path.read_text()), flavor, product, source_identity(args), file_digest)
    return receipt


def record(args: argparse.Namespace) -> None:
    regular_prefix(args.prefix)
    source = source_identity(args)
    cache = args.cmake_dir / "CMakeCache.txt"
    flags = BUILD["configured_mode"](cache, expected_flags(args.flavor))
    BUILD["configured_mode"](cache, {"CMAKE_BUILD_TYPE": args.config}, "STRING")
    receipt: dict
    if (args.prefix / RECEIPT).exists():
        receipt = checked_receipt(args, False)
    else:
        receipt = {"schema_version": 2, "source": source, "config": args.config, "flavors": {}}
    if args.flavor in receipt["flavors"]:
        raise ValueError("refusing to replace an already recorded WASM flavor")
    product = wasm_product(args.prefix, args.flavor, install_notice=True)
    runtime = RUNTIME["run_probe"](args.prefix, args.flavor, product, source, file_digest)
    runtime_name = f"ort-webgpu-wasm.{args.flavor}.runtime.json"
    BUILD["write_receipt"](args.prefix, runtime, filename=runtime_name)
    print("WASM-FACTORY-RECORD: " + json.dumps(runtime, sort_keys=True), file=sys.stderr)
    RUNTIME["validate"](runtime, args.flavor, product, source, file_digest)
    if product != wasm_product(args.prefix, args.flavor):
        raise ValueError("WASM product changed during factory verification")
    receipt["flavors"][args.flavor] = {"configured_flags": flags,
        "cmake_cache_sha256": hashlib.sha256(cache.read_bytes()).hexdigest(), "product": product,
        "runtime": {"path": runtime_name, "sha256": file_digest(args.prefix / runtime_name)}}
    BUILD["write_receipt"](args.prefix, receipt, filename=RECEIPT)


def verify(args: argparse.Namespace) -> None:
    if args.flavors == "true":
        checked_receipt(args, True)
    else:
        regular_prefix(args.prefix)
        if (args.prefix / RECEIPT).exists() or any(args.prefix.glob("ort-wasm-simd-threaded.asyncify.*")) or any(args.prefix.glob("ort-wasm-simd-threaded.jspi.*")):
            raise ValueError("disabled WASM flavors retain unexpected plugin artifacts")
    if not any(args.prefix.glob("*.wasm")):
        raise ValueError("no WASM artifacts were built")


def replay(args: argparse.Namespace) -> None:
    receipt = checked_receipt(args, True)
    for flavor in FLAVORS:
        product = receipt["flavors"][flavor]["product"]
        result = RUNTIME["run_probe"](args.prefix, flavor, product, source_identity(args), file_digest)
        print("WASM-FACTORY-REPLAY: " + json.dumps(result, sort_keys=True))
        RUNTIME["validate"](result, flavor, product, source_identity(args), file_digest)
    if checked_receipt(args, True) != receipt:
        raise ValueError("WASM factory receipts changed during replay")


def cache_files(prefix: Path) -> dict[str, str]:
    regular_prefix(prefix)
    return {p.name: file_digest(p) for p in sorted(prefix.iterdir()) if p.name not in (CACHE, ".complete")}


def recipe_fingerprint() -> dict[str, str]:
    root = Path(__file__).resolve().parent.parent
    names = ("40-build-wasm.sh", "build-onnxruntime.sh", "web-wasm-cache.sh", "lib/common.sh",
             "lib/ort-webgpu-build-proof.py", "lib/ort-webgpu-wasm-proof.py",
             *("lib/" + name for name in RUNTIME["COMPANIONS"]))
    return {name: file_digest(root / name) for name in names}


def cache_identity(args: argparse.Namespace) -> dict:
    return {"schema_version": 1, "source": source_identity(args), "config": args.config,
            "webgpu_flavors": args.flavors, "recipe": recipe_fingerprint(), "files": cache_files(args.prefix)}


def seal_cache(args: argparse.Namespace) -> None:
    verify(args)
    BUILD["write_receipt"](args.prefix, cache_identity(args), filename=CACHE)
    BUILD["write_receipt"](args.prefix, {"cache_sha256": file_digest(args.prefix / CACHE)}, filename=".complete")


def verify_cache(args: argparse.Namespace) -> None:
    regular_prefix(args.prefix)
    file_digest(args.prefix / ".complete")
    marker = json.loads((args.prefix / ".complete").read_text())
    if marker != {"cache_sha256": file_digest(args.prefix / CACHE)}:
        raise ValueError("WASM cache marker differs from its manifest")
    data = json.loads((args.prefix / CACHE).read_text())
    if data != cache_identity(args):
        raise ValueError("WASM shared-cache source, mode or bytes differ")
    verify(args)


def reset(args: argparse.Namespace) -> None:
    regular_prefix(args.prefix)
    entries = list(args.prefix.iterdir())
    if any(p.is_symlink() or not p.is_file() for p in entries):
        raise ValueError("refusing to reset a WASM prefix with nonregular entries")
    for path in entries:
        path.unlink()


def copy_cache(args: argparse.Namespace) -> None:
    verify_cache(args)
    source = args.prefix.resolve()
    target = args.destination.resolve()
    if source == target or source.is_relative_to(target) or target.is_relative_to(source):
        raise ValueError("WASM cache and destination must not overlap")
    files = cache_files(args.prefix)
    delivered = copy.copy(args)
    delivered.prefix = args.destination
    reset(delivered)
    for name in files:
        shutil.copy2(args.prefix / name, args.destination / name)
    if cache_files(args.destination) != files:
        raise ValueError("WASM cache copy changed artifact bytes")
    verify(delivered)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("record", "verify", "replay", "seal-cache", "verify-cache", "reset", "copy-cache"))
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--source-ref", required=True)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--config", choices=("Release", "RelWithDebInfo", "MinSizeRel", "Debug"), required=True)
    parser.add_argument("--flavors", choices=("true", "false"), default="true")
    parser.add_argument("--flavor", choices=FLAVORS)
    parser.add_argument("--cmake-dir", type=Path)
    parser.add_argument("--destination", type=Path)
    return parser.parse_args()


def main() -> int:
    try:
        args = arguments()
        source_identity(args)
        if args.action == "record" and (args.flavor is None or args.cmake_dir is None):
            raise ValueError("record requires a flavor and its actual CMake directory")
        if args.action == "copy-cache" and args.destination is None:
            raise ValueError("copy-cache requires an explicit destination")
        {"record": record, "verify": verify, "replay": replay, "seal-cache": seal_cache, "verify-cache": verify_cache,
         "reset": reset, "copy-cache": copy_cache}[args.action](args)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"WASM-PROOF FAIL: {error}", file=sys.stderr)
        return 1
    print("WASM-PROOF OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
