#!/usr/bin/env python3
"""Run delivered media factories in fresh GIL/FT environments; this proves no device, WASM or inference."""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ort_webgpu_runtime as runtime


def selected_wheel(prefix: Path, pool: Path, phase: str, source_ref: str) -> Path:
    """The completed delivery chooses one collected wheel, never a glob or an unrepaired build product."""
    receipt = runtime.sourced_receipt(prefix, source_ref)
    product = runtime.completed_product(prefix, receipt, phase)
    if product is None:
        raise ValueError(f"missing delivered {phase} wheel for {prefix}")
    name = product["wheel"]
    if Path(name).name != name or not name.endswith(".whl"):
        raise ValueError("invalid delivered wheel basename")
    wheel = (pool / name).resolve(strict=True)
    wheel.relative_to(pool.resolve(strict=True))
    if not wheel.is_file():
        raise ValueError("delivered wheel is not a regular file")
    return wheel


def save_streams(log: Path, result: subprocess.CompletedProcess[str] | subprocess.TimeoutExpired) -> None:
    """Timeout evidence is bytes even when the normal child transport uses text mode."""
    for name, stream in (("stdout", result.stdout), ("stderr", result.stderr)):
        output = stream.decode(errors="replace") if isinstance(stream, bytes) else (stream or "")
        log.with_suffix(f".{name}.log").write_text(output)


def run_logged(command: list[str], log: Path, timeout: int) -> str:
    """Keep each child's exact argv and both streams before propagating its raw failure."""
    log.with_suffix(".argv.json").write_text(json.dumps(command, indent=2) + "\n")
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        save_streams(log, error)
        raise
    save_streams(log, result)
    result.check_returncode()
    return result.stdout


def child_proof(python: Path, prefix: Path, phase: str, args: argparse.Namespace, work: Path) -> dict:
    """Every phase executes the canonical factory and precise negative control in its own process."""
    command = [str(python), "-I", str(Path(runtime.__file__).resolve()), "--prefix", str(prefix),
               "--phase", phase, "--source-ref", args.source_ref]
    output = run_logged(command, work / "factory", args.timeout)
    rows = [line.removeprefix("WEBGPU-FACTORY OK: ") for line in output.splitlines()
            if line.startswith("WEBGPU-FACTORY OK: ")]
    if len(rows) != 1 or any(line.startswith("WEBGPU-FACTORY FAIL:") for line in output.splitlines()):
        raise ValueError("factory child lacks one successful verdict")
    result = json.loads(rows[0])
    if result.get("phase") != phase:
        raise ValueError("factory child returned a different phase")
    (work / "proof.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def python_proof(prefix: Path, phase: str, args: argparse.Namespace, work: Path) -> dict:
    """Pinned NumPy supplies normal package import; only the receipt-selected ORT wheel is installed."""
    interpreter, pool = ((args.gil_python, args.gil_wheels) if phase == "gil"
                         else (args.ft_python, args.ft_wheels))
    wheel = selected_wheel(prefix, pool, phase, args.source_ref)
    environment = work / "venv"
    run_logged([args.uv, "venv", "--python", str(interpreter), str(environment)], work / "venv", args.timeout)
    python = environment / "bin/python"
    install = [args.uv, "pip", "install", "--python", str(python), "--no-deps", "--only-binary=:all:"]
    if not args.allow_network:
        install.append("--offline")
    run_logged([*install, f"numpy=={args.numpy_version}", str(wheel)], work / "install", args.timeout)
    return child_proof(python, prefix, phase, args, work)


def prove_media(args: argparse.Namespace) -> dict:
    runtime.require_prefixes(args.prefix)
    if not args.source_ref or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.numpy_version):
        raise ValueError("expected source ref and exact NumPy version are required")
    if args.timeout <= 0:
        raise ValueError("child timeout must be positive")
    args.work_dir.mkdir(mode=0o700)
    results = []
    for index, prefix in enumerate(args.prefix):
        for phase in ("native", "gil", "free-threaded"):
            work = args.work_dir / f"{index}-{phase}"
            work.mkdir()
            result = (child_proof(Path(sys.executable), prefix, phase, args, work) if phase == "native"
                      else python_proof(prefix, phase, args, work))
            results.append(result)
    result = {"phases": results, "numpy_version": args.numpy_version,
              "scope": "Native/GIL/FT factory and negative controls only; no WASM, device or inference."}
    (args.work_dir / "receipt.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", action="append", type=Path, required=True)
    parser.add_argument("--gil-python", type=Path, required=True)
    parser.add_argument("--ft-python", type=Path, required=True)
    parser.add_argument("--gil-wheels", type=Path, default=Path("/opt/wheels"))
    parser.add_argument("--ft-wheels", type=Path, default=Path("/opt/wheels-free-threaded"))
    parser.add_argument("--numpy-version", required=True)
    parser.add_argument("--source-ref", required=True)
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--uv", default="uv")
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--allow-network", action="store_true")
    return parser


def arguments() -> argparse.Namespace:
    return argument_parser().parse_args()


def run_cli(action: Callable[[], dict], marker: str) -> int:
    try:
        result = action()
    except subprocess.CalledProcessError as error:
        print(f"{marker} FAIL: child status {error.returncode}", file=sys.stderr)
        return error.returncode if error.returncode > 0 else 128 - error.returncode
    except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        print(f"{marker} FAIL: {error}", file=sys.stderr)
        return 1
    print(marker + " OK: " + json.dumps(result, sort_keys=True))
    return 0


def main() -> int:
    return run_cli(lambda: prove_media(arguments()), "WEBGPU-MEDIA")


if __name__ == "__main__":
    sys.exit(main())
