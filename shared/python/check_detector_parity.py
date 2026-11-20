#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Three isolated detector processes (CPU, GPU twice) on one photo, each run twice, compared pairwise.

A consumer's scripts/windows/check_gpu_detector_parity.py keeps what is its own (the launcher command and the
model check) and calls `check_parity` with its pinned hub; the runs, profiles and comparisons live here.
"""

from __future__ import annotations

import hashlib
import itertools
import os
import re
import stat
import sys
import tempfile
from collections.abc import Callable
from pathlib import Path

# The two-cats photo every consumer's parity run reads.
FIXTURE_SHA256 = "6d375ac20fadfd400b3033084f8b0581dcc145f7c14e3b24b97975e379c52999"
RUNTIME = "onnxruntime.dll"
# Under the consumer's pinned hub checkout, which the caller names.
COMPARATOR = "shared/python/compare_detector_parity.py"
INTERVALS = "shared/python/verify_ort_profile.py"
DXGI = "windows/scripts/diagnostics/verify-dxgi-adapter.py"
LABELS = ("cpu", "cpu-repeat", "gpu1", "gpu1-repeat", "gpu2", "gpu2-repeat")

Run = Callable[..., object]
# (label, output, repeat output, profile prefix) -> the packaged binary's command line.
Launch = Callable[[str, Path, Path, Path], list[str]]


def validate_device(device: str, index: str) -> None:
    """Only a GPU provider, and a DirectML adapter index that is a plain non-negative int32."""
    if (
        device not in {"cuda", "directml"}
        or not re.fullmatch(r"0|[1-9][0-9]*", index)
        or int(index) > 2147483647
    ):
        raise ValueError("invalid GPU provider or DirectML adapter index")


def verify_fixture(fixture: Path) -> None:
    """The photo is the one every consumer's expected detections were taken from."""
    if hashlib.sha256(fixture.read_bytes()).hexdigest() != FIXTURE_SHA256:
        raise ValueError("two-cats fixture does not match its expected digest")


def verify_runtime(stage: Path) -> Path:
    """The extracted package's own ONNX Runtime: a regular file directly in the stage, no link or reparse point."""
    runtime = stage / RUNTIME
    if not runtime.is_file():
        raise ValueError(f"required packaged file missing: {runtime}")
    metadata = runtime.lstat()
    if (
        runtime.resolve(strict=True).parent != stage.resolve(strict=True)
        or runtime.is_symlink()
        or getattr(metadata, "st_file_attributes", 0) & 0x400
        or not stat.S_ISREG(metadata.st_mode)
    ):
        raise ValueError("ONNX Runtime escapes the extracted package")
    return runtime


def child_environment(
    stage: Path, device: str, index: str, extra: dict[str, str] | None = None
) -> dict[str, str]:
    """Select the bundled runtime and default detector settings; no inherited override reaches the child."""
    env = os.environ.copy()
    for key in list(env):
        if key.upper().startswith(("KATAGLYPHIS_", "ORT_", "MIGRAPHX_", "GST_")):
            del env[key]
    env.update(extra or {})
    env["KATAGLYPHIS_ORT_DEVICE"] = device
    env["ORT_DYLIB_PATH"] = str(stage / RUNTIME)
    if device == "directml":
        env["KATAGLYPHIS_DIRECTML_DEVICE_ID"] = index
    if device == "cpu" and os.name == "nt":
        env["PATH"] = os.pathsep.join(
            (str(stage), str(Path(env["SYSTEMROOT"]) / "System32"))
        )
    return env


def verify_adapter(hub: Path, device: str, index: str, run: Run) -> None:
    """A DirectML run names a physical AMD adapter, never the software one."""
    if device != "directml":
        return
    dxgi = hub / DXGI
    if not dxgi.is_file():
        raise ValueError("pinned physical DXGI adapter verifier missing")
    run([sys.executable, "-I", str(dxgi), "--vendor", "amd", "--index", index])


def check_parity(
    hub: Path,
    stage: Path,
    device: str,
    index: str,
    work: Path,
    launch: Launch,
    run: Run,
    extra_env: dict[str, str] | None = None,
) -> Path:
    """CPU, then the GPU twice, each with a repeat and one provider profile; every pair of outputs is compared."""
    py = [sys.executable, "-I"]
    comparator, intervals = hub / COMPARATOR, hub / INTERVALS
    for path in (comparator, intervals):
        if not path.is_file():
            raise ValueError(f"required packaged file or pinned helper missing: {path}")
    for label, selected in (("cpu", "cpu"), ("gpu1", device), ("gpu2", device)):
        output, repeat, profile = (
            work / f"{label}.json",
            work / f"{label}-repeat.json",
            work / f"{label}-profile",
        )
        run(
            launch(label, output, repeat, profile),
            cwd=stage,
            env=child_environment(stage, selected, index, extra_env),
        )
        profiles = list(work.glob(f"{label}-profile*.json"))
        if len(profiles) != 1 or not output.is_file() or not repeat.is_file():
            raise ValueError(f"expected one {label} detector output and provider profile")
        run(py + [str(intervals), str(profiles[0]), "--device", selected, "--min-runs", "2"])
    for left, right in itertools.combinations(LABELS, 2):
        # Only against the CPU output do the score bounds apply; GPU runs must agree with each other.
        mode = [] if left == "cpu" else ["--pairwise"]
        run(py + [str(comparator), str(work / f"{left}.json"), str(work / f"{right}.json")] + mode)
    return work


def new_work(prefix: str, temp_root: Path) -> Path:
    """A fresh directory for one parity run's outputs and profiles."""
    return Path(tempfile.mkdtemp(prefix=prefix, dir=temp_root))
