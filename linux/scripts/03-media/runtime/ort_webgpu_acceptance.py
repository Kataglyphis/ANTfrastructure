#!/usr/bin/env python3
"""Replay native/GIL/FT and both compiled WASM factories; no device, inference or final-consumer acceptance."""
from __future__ import annotations

import argparse
import copy
import inspect
import json
import sys
from pathlib import Path
from types import ModuleType

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ort_webgpu_delivery import source_api

media = source_api("03-media/runtime/ort_webgpu_media.py", ("argument_parser", "prove_media", "run_logged", "run_cli"))


def wasm_arguments(args: argparse.Namespace) -> argparse.Namespace:
    return argparse.Namespace(prefix=args.wasm_prefix, source_ref=args.source_ref,
                              source_revision=args.source_revision, config=args.wasm_config, flavors="true")


def source_bindings(args: argparse.Namespace, wasm: ModuleType) -> tuple[dict, dict]:
    media.runtime.require_prefixes(args.prefix)
    source = wasm.source_identity(args)
    build = media.runtime.delivery.build_api()
    paths = []
    for prefix in args.prefix:
        receipt = media.runtime.sourced_receipt(prefix, args.source_ref)
        if receipt["source"] != source:
            raise ValueError("native/Python and WASM source revisions differ")
        for phase in ("gil", "free-threaded"):
            if (media.runtime.completed_product(prefix, receipt, phase) is None
                    or receipt["phases"][phase]["configured_flags"] != dict.fromkeys(build.FLAGS, "ON")):
                raise ValueError("acceptance requires delivered enabled static WebGPU in every native/Python phase")
        paths.append(prefix / build.RECEIPT)
    compiled = wasm.checked_receipt(wasm_arguments(args), True)
    paths.extend([args.wasm_prefix / wasm.RECEIPT,
                  *(args.wasm_prefix / f"ort-webgpu-wasm.{flavor}.runtime.json" for flavor in wasm.FLAVORS)])
    return {str(path.resolve()): wasm.file_digest(path) for path in paths}, compiled


def replay_wasm(args: argparse.Namespace, wasm: ModuleType, compiled: dict) -> list[dict]:
    command = [sys.executable, "-I", str(Path(inspect.getfile(wasm)).resolve()), "replay", "--prefix", str(args.wasm_prefix),
               "--source-ref", args.source_ref, "--source-revision", args.source_revision,
               "--config", args.wasm_config, "--flavors", "true"]
    output = media.run_logged(command, args.work_dir / "wasm", args.timeout)
    results = [json.loads(line.removeprefix("WASM-FACTORY-REPLAY: ")) for line in output.splitlines()
               if line.startswith("WASM-FACTORY-REPLAY: ")]
    if tuple(row.get("flavor") for row in results) != wasm.FLAVORS:
        raise ValueError("fresh replay must report exactly Asyncify and JSPI once each")
    for flavor, result in zip(wasm.FLAVORS, results, strict=True):
        wasm.RUNTIME["validate"](result, flavor, compiled["flavors"][flavor]["product"],
                                 wasm.source_identity(args), wasm.file_digest)
    return results


def prove_acceptance(args: argparse.Namespace) -> dict:
    wasm = source_api("03-media/build/onnxruntime/build/lib/ort-webgpu-wasm-proof.py",
                      ("checked_receipt", "source_identity", "file_digest"))
    before, compiled = source_bindings(args, wasm)
    args.work_dir.mkdir(mode=0o700)
    native_args = copy.copy(args)
    native_args.work_dir = args.work_dir / "native"
    native = media.prove_media(native_args)
    results = replay_wasm(args, wasm, compiled)
    if source_bindings(args, wasm) != (before, compiled):
        raise ValueError("source or compiled factory receipts changed during acceptance")
    result = {"source": wasm.source_identity(args), "native": native, "wasm": results,
              "input_receipts_sha256": before,
              "scope": "Native/GIL/FT and Asyncify/JSPI factory controls only; no device, inference or final consumers."}
    (args.work_dir / "receipt.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def arguments() -> argparse.Namespace:
    parser = media.argument_parser()
    parser.description = __doc__
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--wasm-prefix", required=True, type=Path)
    parser.add_argument("--wasm-config", required=True, choices=("Release", "RelWithDebInfo", "MinSizeRel", "Debug"))
    return parser.parse_args()


def main() -> int:
    return media.run_cli(lambda: prove_acceptance(arguments()), "WEBGPU-MEDIA-ACCEPTANCE")


if __name__ == "__main__":
    sys.exit(main())
