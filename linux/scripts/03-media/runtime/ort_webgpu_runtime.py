#!/usr/bin/env python3
"""Prove native/Python factories in isolated owning processes, without device or inference claims."""
from __future__ import annotations

import argparse
import hashlib
import importlib
import importlib.machinery
import json
import subprocess
import sys
import sysconfig
from itertools import pairwise
from pathlib import Path
from types import ModuleType

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ort_webgpu_delivery as delivery

PROVIDER = "WebGpuExecutionProvider"
MISSING = f"[ONNXRuntimeError] : 1 : FAIL : Execution provider library: {PROVIDER} was not registered."
DEFAULT_PREFIXES = (Path("/usr/local/lib/onnxruntime-cpu"), Path("/usr/local/lib/onnxruntime-gpu"))


def interpreter_mode(phase: str) -> None:
    """An FT wheel must execute with the GIL disabled before and after registration."""
    free_threaded = bool(sysconfig.get_config_var("Py_GIL_DISABLED"))
    if free_threaded != (phase == "free-threaded"):
        raise ValueError(f"interpreter ABI does not match {phase}")
    if free_threaded and (not callable(getattr(sys, "_is_gil_enabled", None)) or sys._is_gil_enabled()):
        raise ValueError("free-threaded WebGPU probe has the GIL enabled")


def loaded_product(binding: ModuleType) -> tuple[Path, str]:
    """Only the imported extension's actual bytes may satisfy a Python product receipt."""
    spec = binding.__spec__
    if spec is None or not isinstance(spec.loader, importlib.machinery.ExtensionFileLoader):
        raise ValueError("ONNX Runtime binding is not a loaded native extension")
    filename, origin = binding.__file__, spec.origin
    if not isinstance(filename, str) or not isinstance(origin, str):
        raise TypeError("loaded extension has no concrete file and origin")
    path = Path(filename).resolve(strict=True)
    if Path(origin).resolve(strict=True) != path:
        raise ValueError("loaded binding origin differs from its module file")
    return path, linker_digest(path)


def linker_digest(path: Path) -> str:
    """Bounded ELF hashing covers either an extension or the shipped native probe."""
    if not 0 < path.stat().st_size <= delivery.build_api().MAX_PRODUCT_BYTES:
        raise ValueError("invalid loaded linker product size")
    with path.open("rb") as stream:
        return delivery.build_api().elf_digest(stream, str(path))


def completed_product(prefix: Path, receipt: dict, phase: str) -> dict | None:
    """An original hash or unfinished repair never proves final runtime delivery."""
    delivery.original_product(receipt, "gil")
    if phase not in receipt["phases"]:
        return None
    if any("delivery_pending" in record for record in receipt["phases"].values()):
        raise ValueError("WebGPU delivery still has a pending repair")
    record = receipt["phases"][phase]
    product = delivery.current_product(receipt, phase)
    if product is None:
        return None
    if record["configured_flags"] != receipt["phases"]["gil"]["configured_flags"]:
        raise ValueError("native and Python WebGPU modes disagree")
    history = record.get("wheel_delivery", [])
    if not history or any(a["after_manifest_sha256"] != b["before_manifest_sha256"]
                          for a, b in pairwise(history)):
        raise ValueError("WebGPU delivery has no completed manifest history")
    manifest = prefix / next(name for name, value in delivery.PHASES.items() if value == phase)
    body = manifest.read_bytes()
    if hashlib.sha256(body).hexdigest() != history[-1]["after_manifest_sha256"]:
        raise ValueError("final WebGPU manifest changed after delivery")
    label = product["wheel"] + "!" + product["member"]
    rows = [line.split(None, 1) for line in body.decode().splitlines() if line.strip()]
    matching = [row for row in rows if len(row) == 2 and row[1].strip() == label]
    if matching != [[product["sha256"], label]]:
        raise ValueError("final manifest does not uniquely retain the Python product")
    return product


def owning_receipt(prefixes: list[Path], phase: str, source_ref: str, path: Path, digest: str) -> dict:
    """A loaded extension must match exactly one checked prefix, never just its native core."""
    matches = []
    for prefix in prefixes:
        receipt = sourced_receipt(prefix, source_ref)
        product = completed_product(prefix, receipt, phase)
        if product is not None and product["sha256"] == digest:
            if tuple(path.parts[-3:]) != tuple(Path(product["member"]).parts):
                raise ValueError("loaded extension does not retain its delivered member path")
            matches.append({"prefix": str(prefix.resolve()), "source": receipt["source"],
                            "mode": receipt["phases"][phase]["configured_flags"][delivery.build_api().FLAGS[0]]})
    if len(matches) != 1:
        raise ValueError(f"loaded Python binding matches {len(matches)} delivered WebGPU prefixes, expected one")
    return matches[0]


def require_missing(binding: ModuleType) -> None:
    """Only ORT's precise missing-registration failure proves the negative control."""
    error_type = getattr(binding, "Fail", None)
    if not isinstance(error_type, type) or not issubclass(error_type, Exception):
        raise TypeError("ONNX Runtime binding has no required Fail exception API")
    try:
        binding.unregister_execution_provider_library(PROVIDER)
    except error_type as error:
        if str(error) != MISSING:
            raise ValueError("unexpected WebGPU unregistration failure") from error
    else:
        raise ValueError("WebGPU negative control unexpectedly unregistered a factory")


def prove(prefixes: list[Path], phase: str, source_ref: str) -> dict:
    """Both modes require a negative control; static mode first requires a registered factory."""
    require_prefixes(prefixes)
    interpreter_mode(phase)
    binding = importlib.import_module("onnxruntime.capi.onnxruntime_pybind11_state")
    interpreter_mode(phase)
    path, digest = loaded_product(binding)
    result = owning_receipt(prefixes, phase, source_ref, path, digest)
    if not callable(getattr(binding, "unregister_execution_provider_library", None)):
        raise TypeError("ONNX Runtime binding has no required unregistration API")
    if result["mode"] == "ON":
        binding.unregister_execution_provider_library(PROVIDER)
    else:
        require_missing(binding)
    require_missing(binding)
    interpreter_mode(phase)
    return {**result, "phase": phase, "extension": str(path), "sha256": digest,
            "registered": result["mode"] == "ON", "negative_control": "missing-registration"}


def require_prefixes(prefixes: list[Path]) -> None:
    if not prefixes or len({p.resolve() for p in prefixes}) != len(prefixes):
        raise ValueError("at least one distinct owning ORT prefix is required")


def sourced_receipt(prefix: Path, source_ref: str) -> dict:
    receipt = delivery.load_receipt(prefix)
    delivery.original_product(receipt, "gil")
    if receipt["source"]["ref"] != source_ref:
        raise ValueError("WebGPU receipt does not match the expected source ref")
    return receipt


def native_core(prefix: Path, source_ref: str) -> dict:
    """The explicit core and target-native probe must retain their checked bytes through execution."""
    receipt = sourced_receipt(prefix, source_ref)
    product = delivery.build_api().native_product(prefix)
    core = (prefix / product["path"]).resolve(strict=True)
    probe = (prefix / "bin/ort-webgpu-factory-probe").resolve(strict=True)
    probe.relative_to(prefix.resolve())
    digest = linker_digest(probe)
    mode = receipt["phases"]["gil"]["configured_flags"][delivery.build_api().FLAGS[0]]
    result = subprocess.run([str(probe), str(core), mode], capture_output=True, text=True, check=False, timeout=60)
    sentinels = [line for line in result.stdout.splitlines() if line.startswith(f"WEBGPU-NATIVE OK: mode={mode} ")]
    failure = any(line.startswith("WEBGPU-NATIVE FAIL:") for line in (result.stdout + "\n" + result.stderr).splitlines())
    if result.returncode != 0 or len(sentinels) != 1 or failure:
        raise ValueError(f"native WebGPU factory probe failed ({result.returncode}): {result.stdout}{result.stderr}")
    if delivery.build_api().native_product(prefix) != product or linker_digest(probe) != digest:
        raise ValueError("native WebGPU core or probe changed during execution")
    return {"prefix": str(prefix.resolve()), "source": receipt["source"], "mode": mode,
            "core": product, "probe_sha256": digest, "verdict": sentinels[0]}


def prove_native(prefixes: list[Path], source_ref: str) -> dict:
    """Every requested native core needs its own isolated C API proof."""
    require_prefixes(prefixes)
    return {"phase": "native", "cores": [native_core(prefix, source_ref) for prefix in prefixes]}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", action="append", type=Path)
    parser.add_argument("--phase", choices=("native", "gil", "free-threaded"), required=True)
    parser.add_argument("--source-ref", required=True)
    args = parser.parse_args()
    prefixes = args.prefix if args.prefix is not None else [p for p in DEFAULT_PREFIXES if p.is_dir()]
    try:
        if not args.source_ref:
            raise ValueError("the expected ORT source ref is required")
        result = (prove_native(prefixes, args.source_ref) if args.phase == "native"
                  else prove(prefixes, args.phase, args.source_ref))
    except (OSError, ValueError, KeyError, TypeError, ImportError) as error:
        print(f"WEBGPU-FACTORY FAIL: {error}", file=sys.stderr)
        return 1
    print("WEBGPU-FACTORY OK: " + json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
