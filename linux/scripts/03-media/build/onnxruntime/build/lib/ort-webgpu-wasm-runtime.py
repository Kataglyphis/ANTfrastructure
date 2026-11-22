"""Execute the actual WASM factory entry; no adapter, browser, inference or global teardown proof."""
from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path

HERE = Path(__file__).resolve().parent
COMPANIONS = ("webgpu-factory-probe/probe.c", "webgpu-factory-probe/wasm.cmake",
              "webgpu-factory-probe/run-wasm.mjs", "webgpu-factory-probe/LICENSE", "ort-webgpu-wasm-runtime.py")


def recipe(digest: Callable[[Path], str]) -> dict[str, str]:
    return {name: digest(HERE / name) for name in COMPANIONS}


def decoded(value: str | bytes | None) -> str:
    return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value or ""


def inputs_unchanged(paths: list[Path], before: list[str], before_recipe: dict[str, str],
                     digest: Callable[[Path], str]) -> bool:
    try:
        return before == [digest(path) for path in paths] and before_recipe == recipe(digest)
    except (OSError, ValueError):
        return False


def run_probe(prefix: Path, flavor: str, product: dict, source: dict,
              digest: Callable[[Path], str]) -> dict:
    node = Path(shutil.which("node") or "node").resolve(strict=True)
    driver = HERE / "webgpu-factory-probe/run-wasm.mjs"
    paths = [prefix / product["path"], prefix / product["loader"]["path"], node]
    before = [digest(path) for path in paths]
    before_recipe = recipe(digest)
    command = [str(node), str(driver), str(paths[1].resolve()), str(paths[0].resolve()), flavor]
    timed_out = False
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False, timeout=120)
        status, stdout, stderr = result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired as error:
        timed_out = True
        status, stdout, stderr = None, decoded(error.stdout), decoded(error.stderr)
    sys.stdout.write(stdout)
    sys.stderr.write(stderr)
    return {"schema_version": 1, "flavor": flavor, "source": source, "product": product,
            "recipe": before_recipe, "node_sha256": before[2], "returncode": status,
            "timed_out": timed_out, "stdout": stdout, "stderr": stderr,
            "unchanged_inputs": inputs_unchanged(paths, before, before_recipe, digest)}


def child_output(proof: dict) -> tuple[str, str]:
    if (type(proof.get("returncode")) is not int or proof["returncode"] != 0
            or proof.get("timed_out") is not False or proof.get("unchanged_inputs") is not True
            or not re.fullmatch(r"[0-9a-f]{64}", proof.get("node_sha256", ""))):
        raise ValueError("WASM factory probe failed, timed out or changed its inputs")
    stdout, stderr = proof["stdout"], proof["stderr"]
    if not isinstance(stdout, str) or not isinstance(stderr, str) or len(stdout) + len(stderr) > 2 * 1024 * 1024:
        raise ValueError("WASM factory output is invalid or unbounded")
    return stdout, stderr


def c_api_success(stdout: str, stderr: str, source_ref: str) -> None:
    success = [line for line in stdout.splitlines() if line.startswith("WEBGPU-WASM OK:")]
    failed = ("WEBGPU-WASM FAIL:", "WEBGPU-WASM-RUNTIME FAIL:")
    if len(success) != 1 or any(marker in stdout + stderr for marker in failed):
        raise ValueError("WASM factory probe lacks one clean C API success")
    match = re.fullmatch(r"WEBGPU-WASM OK: mode=ON api=([1-9][0-9]*) version=(\S+)", success[0])
    if not match or (re.fullmatch(r"v?[0-9]+\.[0-9]+\.[0-9]+", source_ref)
                     and match[2] != source_ref.removeprefix("v")):
        raise ValueError("WASM factory C API mode or version differs")


def node_identity(stdout: str, flavor: str) -> None:
    metadata = [line.removeprefix("WEBGPU-WASM-NODE: ") for line in stdout.splitlines()
                if line.startswith("WEBGPU-WASM-NODE: ")]
    if len(metadata) != 1:
        raise ValueError("WASM factory proof lacks one Node runtime identity")
    node = json.loads(metadata[0])
    if (not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", node["version"])
            or type(node["jspiSupported"]) is not bool or (flavor == "jspi" and not node["jspiSupported"])):
        raise ValueError("WASM factory Node runtime cannot prove the requested flavor")


def validate(proof: dict, flavor: str, product: dict, source: dict,
             digest: Callable[[Path], str]) -> None:
    if (proof.get("schema_version") != 1 or proof.get("flavor") != flavor
            or proof.get("product") != product or proof.get("source") != source
            or proof.get("recipe") != recipe(digest)):
        raise ValueError("WASM factory proof source, flavor, product or recipe differs")
    stdout, stderr = child_output(proof)
    c_api_success(stdout, stderr, source["ref"])
    node_identity(stdout, flavor)
