"""Independent fixture flags and minimal modules do not model a compiled ORT provider or JS loader."""
from __future__ import annotations

import argparse
from pathlib import Path


def expected_flags(flavor: str) -> dict[str, str]:
    if flavor not in ("asyncify", "jspi"):
        raise ValueError("unknown fixture flavor")
    return {"onnxruntime_USE_WEBGPU": "ON", "onnxruntime_USE_EP_API_ADAPTERS": "ON",
            "onnxruntime_WEBGPU_STATIC_PLUGIN": "ON", "onnxruntime_USE_EXTERNAL_DAWN": "OFF",
            "onnxruntime_ENABLE_WEBASSEMBLY_THREADS": "ON",
            "onnxruntime_ENABLE_WEBASSEMBLY_JSPI": "ON" if flavor == "jspi" else "OFF"}


def create_flavor(cmake: Path, prefix: Path, flavor: str, config: str = "Release", products: bool = True) -> None:
    flags = expected_flags(flavor)
    cmake.mkdir(parents=True, exist_ok=True)
    prefix.mkdir(parents=True, exist_ok=True)
    (cmake / "CMakeCache.txt").write_text("".join(f"{k}:BOOL={v}\n" for k, v in flags.items())
                                        + f"CMAKE_BUILD_TYPE:STRING={config}\n")
    if not products:
        return
    stem = f"ort-wasm-simd-threaded.{flavor}"
    (prefix / (stem + ".wasm")).write_bytes(b"\0asm\x01\0\0\0")
    (prefix / (stem + ".mjs")).write_text("synthetic nonempty loader fixture")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cmake-dir", type=Path, required=True)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--flavor", choices=("asyncify", "jspi"), required=True)
    parser.add_argument("--config", default="Release")
    parser.add_argument("--config-only", action="store_true")
    args = parser.parse_args()
    create_flavor(args.cmake_dir, args.prefix, args.flavor, args.config, not args.config_only)


if __name__ == "__main__":
    main()
