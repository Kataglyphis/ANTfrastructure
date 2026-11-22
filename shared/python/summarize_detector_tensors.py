#!/usr/bin/env python3
"""Describe recorded model tensors; success validates evidence/input identity, never numerical or GPU acceptance."""

from __future__ import annotations

import argparse
import hashlib
import heapq
import json
import math
import runpy
import sys
from array import array
from pathlib import Path
from typing import Any, TypedDict

unique = runpy.run_path(
    str(Path(__file__).with_name("compare_detector_parity.py"))
).get("unique")
if not callable(unique):
    raise TypeError("missing canonical duplicate-key reader")


class Tensor(TypedDict):
    shape: tuple[int, ...]
    values: array
    sha256: str


def regular_bytes(path: Path) -> bytes:
    if (
        path.is_symlink()
        or not path.is_file()
        or not 0 < path.stat().st_size <= 1024**3
    ):
        raise ValueError(f"invalid tensor evidence file: {path}")
    return path.read_bytes()


def tensor_shape(entry: Any, name: str) -> tuple[int, ...]:
    if (
        not isinstance(entry, dict)
        or set(entry) != {"path", "shape", "dtype", "byte_order"}
        or entry["path"] != name
        or entry["dtype"] != "float32"
        or entry["byte_order"] != "little"
    ):
        raise ValueError("invalid tensor metadata")
    shape = entry["shape"]
    if (
        not isinstance(shape, list)
        or not shape
        or not all(type(size) is int and size > 0 for size in shape)
    ):
        raise ValueError("invalid tensor shape")
    return tuple(shape)


def read_tensor(directory: Path, number: int, kind: str, entry: Any) -> Tensor:
    name = f"run-{number}-{kind}.f32le"
    shape = tensor_shape(entry, name)
    raw = regular_bytes(directory / name)
    if len(raw) != math.prod(shape) * 4:
        raise ValueError("tensor shape and byte count differ")
    values = array("f")
    if values.itemsize != 4:
        raise ValueError("host float transport is not float32")
    values.frombytes(raw)
    if sys.byteorder != "little":
        values.byteswap()
    if not all(math.isfinite(value) for value in values):
        raise ValueError("nonfinite tensor values")
    return {"shape": shape, "values": values, "sha256": hashlib.sha256(raw).hexdigest()}


def read_run(directory: Path, number: int) -> tuple[Tensor, Tensor]:
    data = json.loads(
        regular_bytes(directory / f"run-{number}.json"), object_pairs_hook=unique
    )
    if (
        not isinstance(data, dict)
        or set(data) != {"schema_version", "run", "input", "output"}
        or type(data["schema_version"]) is not int
        or data["schema_version"] != 1
        or type(data["run"]) is not int
        or data["run"] != number
    ):
        raise ValueError("invalid tensor run identity")
    return read_tensor(directory, number, "input", data["input"]), read_tensor(
        directory, number, "output", data["output"]
    )


def read_directory(directory: Path, runs: int) -> list[tuple[Tensor, Tensor]]:
    if runs < 2 or directory.is_symlink() or not directory.is_dir():
        raise ValueError("two or more runs in a real evidence directory are required")
    expected = {
        f"run-{n}{suffix}"
        for n in range(1, runs + 1)
        for suffix in (".json", "-input.f32le", "-output.f32le")
    }
    if {path.name for path in directory.iterdir()} != expected:
        raise ValueError("tensor evidence roster differs from the requested runs")
    return [read_run(directory, number) for number in range(1, runs + 1)]


def coordinates(index: int, shape: tuple[int, ...]) -> list[int]:
    result = []
    for size in reversed(shape):
        index, value = divmod(index, size)
        result.append(value)
    return list(reversed(result))


def axis_maxima(
    shape: tuple[int, ...], differences: list[float]
) -> dict[str, list[float]]:
    result = {}
    for axis, size in enumerate(shape):
        if not 2 <= size <= 128:
            continue
        maxima = [0.0] * size
        stride = math.prod(shape[axis + 1 :])
        for index, difference in enumerate(differences):
            slot = index // stride % size
            maxima[slot] = max(maxima[slot], difference)
        result[str(axis)] = maxima
    return result


def difference_report(cpu: Tensor, gpu: Tensor) -> dict[str, Any]:
    if cpu["shape"] != gpu["shape"]:
        raise ValueError("model output shapes differ")
    differences = [
        abs(a - b) for a, b in zip(cpu["values"], gpu["values"], strict=True)
    ]
    indices = heapq.nlargest(12, range(len(differences)), key=differences.__getitem__)
    return {
        "shape": cpu["shape"],
        "cpu_sha256": cpu["sha256"],
        "gpu_sha256": gpu["sha256"],
        "elements": len(differences),
        "different_elements": sum(value != 0 for value in differences),
        "max_absolute_difference": max(differences),
        "mean_absolute_difference": math.fsum(differences) / len(differences),
        "rms_difference": math.sqrt(
            math.fsum(value * value for value in differences) / len(differences)
        ),
        "axis_max_absolute_difference": axis_maxima(cpu["shape"], differences),
        "largest_differences": [
            {
                "index": coordinates(i, cpu["shape"]),
                "cpu": cpu["values"][i],
                "gpu": gpu["values"][i],
                "absolute_difference": differences[i],
            }
            for i in indices
            if differences[i] > 0
        ],
    }


def summarize(cpu: Path, gpu: Path, runs: int) -> dict[str, Any]:
    cpu_runs, gpu_runs = read_directory(cpu, runs), read_directory(gpu, runs)
    inputs = [record[0] for record in [*cpu_runs, *gpu_runs]]
    if len({(tensor["shape"], tensor["sha256"]) for tensor in inputs}) != 1:
        raise ValueError(
            "input bytes/shapes differ; provider outputs are not comparable"
        )
    return {
        "schema_version": 1,
        "scope": __doc__,
        "acceptance": False,
        "runs_per_provider": runs,
        "identical_input_sha256": inputs[0]["sha256"],
        "input_shape": inputs[0]["shape"],
        "cpu_repeated_output_bytes_identical": len(
            {record[1]["sha256"] for record in cpu_runs}
        )
        == 1,
        "gpu_repeated_output_bytes_identical": len(
            {record[1]["sha256"] for record in gpu_runs}
        )
        == 1,
        "cross_pairs": [
            {"cpu_run": i, "gpu_run": j, **difference_report(a[1], b[1])}
            for i, a in enumerate(cpu_runs, 1)
            for j, b in enumerate(gpu_runs, 1)
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cpu", type=Path)
    parser.add_argument("gpu", type=Path)
    parser.add_argument("--runs", type=int, default=2)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = summarize(args.cpu, args.gpu, args.runs)
        with args.output.open("x", encoding="utf-8") as stream:
            json.dump(result, stream, indent=2, allow_nan=False)
            stream.write("\n")
    except (OSError, ValueError, TypeError, KeyError) as error:
        parser.exit(1, f"Tensor diagnostic failed: {error}\n")
    print(
        "Tensor evidence summarized; numerical/provider/package acceptance is not established"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
