#!/usr/bin/env python3
# Build receipts bind configured native modes to bytes; they do not prove delivery rewrites, registration, devices or inference.
"""Record each native ONNX Runtime linker product before wheel repair."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import IO

FLAGS = ("onnxruntime_USE_WEBGPU", "onnxruntime_USE_EP_API_ADAPTERS",
         "onnxruntime_WEBGPU_STATIC_PLUGIN", "onnxruntime_USE_EXTERNAL_DAWN")
RECEIPT = "ort-webgpu-build.json"
MAX_PRODUCT_BYTES = 1024 * 1024 * 1024


def configured_mode(cache: Path, expected: str) -> dict[str, str]:
    """Require exactly one native BOOL entry per mode flag."""
    lines = cache.read_text(encoding="utf-8").splitlines()
    flags = {}
    for name in FLAGS:
        entries = [line for line in lines if line.startswith(name + ":")]
        if entries != [f"{name}:BOOL={expected}"]:
            raise ValueError(f"{cache}: {name} does not uniquely match BOOL={expected}")
        flags[name] = expected
    return flags


def elf_digest(stream: IO[bytes], label: str) -> str:
    """Reject non-ELF payloads before recording a linker-product digest."""
    header = stream.read(4)
    if header != b"\x7fELF":
        raise ValueError(f"not an ELF linker product: {label}")
    digest = hashlib.sha256(header)
    while chunk := stream.read(1024 * 1024):
        digest.update(chunk)
    return digest.hexdigest()


def native_product(prefix: Path) -> dict[str, str]:
    """Resolve the installed core within its owning prefix."""
    library = (prefix / "lib/libonnxruntime.so").resolve(strict=True)
    relative = library.relative_to(prefix.resolve())
    if not library.is_file() or not 0 < library.stat().st_size <= MAX_PRODUCT_BYTES:
        raise ValueError(f"invalid native core: {library}")
    with library.open("rb") as stream:
        digest = elf_digest(stream, str(library))
    return {"kind": "native-core", "path": relative.as_posix(), "sha256": digest}


def python_product(prefix: Path, phase: str, without_wheel: bool) -> list[dict[str, str]]:
    """A separate wheel owns each Python extension; the native core proves neither."""
    directory = prefix / ("wheels" if phase == "gil" else "wheels-free-threaded")
    wheels = sorted(directory.glob("*.whl"))
    if without_wheel:
        if phase != "gil" or wheels:
            raise ValueError("a no-wheel build must be a GIL phase with no staged wheel")
        return []
    if len(wheels) != 1:
        raise ValueError(f"expected one {phase} wheel under {directory}, found {len(wheels)}")
    wheel = wheels[0]
    tags = wheel.stem.rsplit("-", 3)
    if len(tags) != 4 or not re.fullmatch(r"onnxruntime(?:_[a-z0-9]+)?-[^-]+", tags[0]):
        raise ValueError(f"invalid ONNX Runtime wheel name: {wheel.name}")
    free_threaded = bool(re.fullmatch(r"cp[0-9]+t", tags[2]))
    if free_threaded != (phase == "free-threaded"):
        raise ValueError(f"wheel ABI does not match {phase}: {wheel.name}")
    with zipfile.ZipFile(wheel) as archive:
        entries = [entry for entry in archive.infolist()
                   if re.fullmatch(r"onnxruntime/capi/onnxruntime_pybind11_state[^/]*[.]so", entry.filename)]
        if len(entries) != 1:
            raise ValueError(f"expected one Python linker product in {wheel.name}")
        entry = entries[0]
        if stat.S_ISLNK(entry.external_attr >> 16) or not 0 < entry.file_size <= MAX_PRODUCT_BYTES:
            raise ValueError(f"invalid wheel linker product: {entry.filename}")
        with archive.open(entry) as stream:
            digest = elf_digest(stream, entry.filename)
    return [{"kind": f"python-{phase}", "wheel": wheel.name, "member": entry.filename, "sha256": digest}]


def initial_receipt(args: argparse.Namespace, flags: dict[str, str]) -> dict:
    """An FT receipt may only extend the same checked GIL build."""
    source = {"ref": args.source_ref, "revision": args.source_revision}
    if args.phase == "gil":
        return {"schema_version": 1, "provider": "WebGpuExecutionProvider", "source": source, "phases": {}}
    previous = json.loads((args.prefix / RECEIPT).read_text(encoding="utf-8"))
    if (previous.get("schema_version") != 1 or previous.get("source") != source
            or previous.get("provider") != "WebGpuExecutionProvider"):
        raise ValueError("free-threaded proof does not match its native/GIL source")
    phases = previous.get("phases", {})
    if set(phases) != {"gil"} or phases["gil"].get("configured_flags") != flags:
        raise ValueError("free-threaded proof requires the same native/GIL WebGPU mode")
    expected_products = [native_product(args.prefix), *python_product(args.prefix, "gil", False)]
    if phases["gil"].get("products") != expected_products:
        raise ValueError("native/GIL products changed before the free-threaded proof")
    return previous


def write_receipt(prefix: Path, receipt: dict) -> None:
    """Validation finishes before an atomic replacement touches the prior receipt."""
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=prefix, delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(receipt, stream, indent=2)
            stream.write("\n")
        temporary.chmod(0o644)
        os.replace(temporary, prefix / RECEIPT)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def record(args: argparse.Namespace) -> None:
    """Record the checked configuration and the exact products that leave it."""
    cache = args.cmake_dir / "CMakeCache.txt"
    flags = configured_mode(cache, args.expected)
    products = python_product(args.prefix, args.phase, args.without_wheel)
    if args.phase == "gil":
        products.insert(0, native_product(args.prefix))
    receipt = initial_receipt(args, flags)
    receipt["phases"][args.phase] = {
        "configured_flags": flags,
        "cmake_cache_sha256": hashlib.sha256(cache.read_bytes()).hexdigest(),
        "products": products,
    }
    write_receipt(args.prefix, receipt)
    print(f"WebGPU BUILD: {args.phase}, mode={args.expected}, {len(products)} linker products: {args.prefix / RECEIPT}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", required=True, type=Path)
    parser.add_argument("--cmake-dir", required=True, type=Path)
    parser.add_argument("--phase", required=True, choices=("gil", "free-threaded"))
    parser.add_argument("--expected", required=True, choices=("ON", "OFF"))
    parser.add_argument("--source-ref", required=True)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--without-wheel", action="store_true")
    args = parser.parse_args()
    if not args.source_ref or not re.fullmatch(r"[a-f0-9]{40}", args.source_revision):
        parser.error("source ref and full Git revision are required")
    try:
        record(args)
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        print(f"ERROR: WebGPU build proof: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
