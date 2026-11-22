#!/usr/bin/env python3
"""Expose a top-level float tensor in a diagnostic model; changed graph outputs can alter fusion."""

from __future__ import annotations

import argparse
import hashlib
import importlib
import json
from pathlib import Path
from typing import Any

SCOPE = "Diagnostic model only; exposing outputs can alter fusion and never establishes original-model or GPU acceptance."


def require_supported(model: Any, api: Any) -> None:
    if model.functions or model.graph.sparse_initializer:
        raise ValueError(
            "Local functions and sparse initializers are outside this diagnostic"
        )
    tensors = list(model.graph.initializer)
    for node in model.graph.node:
        for attribute in node.attribute:
            if attribute.type in (
                api.AttributeProto.GRAPH,
                api.AttributeProto.GRAPHS,
                api.AttributeProto.SPARSE_TENSOR,
                api.AttributeProto.SPARSE_TENSORS,
            ):
                raise ValueError(
                    "Nested graphs and sparse attributes are outside this diagnostic"
                )
            tensors.extend([attribute.t, *attribute.tensors])
    if any(
        t.external_data or t.data_location == api.TensorProto.EXTERNAL for t in tensors
    ):
        raise ValueError("External tensor data is outside this diagnostic")


def graph_bytes(model: Any) -> tuple[tuple[bytes, ...], tuple[bytes, ...]]:
    return (
        tuple(node.SerializeToString(deterministic=True) for node in model.graph.node),
        tuple(
            tensor.SerializeToString(deterministic=True)
            for tensor in model.graph.initializer
        ),
    )


def load(path: Path, expected: str) -> tuple[Any, Any, dict[str, Any]]:
    if (
        path.is_symlink()
        or not path.is_file()
        or not 0 < path.stat().st_size <= 1024**3
    ):
        raise ValueError("Expected a bounded regular model file")
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != expected:
        raise ValueError("Original model SHA256 differs")
    api = importlib.import_module("onnx")
    model = api.load_model_from_string(raw)
    require_supported(model, api)
    api.checker.check_model(model)
    original = graph_bytes(model)
    inferred = api.shape_inference.infer_shapes(
        model, check_type=True, strict_mode=True, data_prop=True
    )
    if graph_bytes(inferred) != original:
        raise ValueError("Shape inference changed nodes or initializer bytes")
    receipt = {
        "schema_version": 1,
        "scope": SCOPE,
        "acceptance": False,
        "original_model_sha256": expected,
        "original_model_bytes": len(raw),
        "onnx_version": api.__version__,
        "original_outputs": [v.name for v in model.graph.output],
    }
    return api, inferred, receipt


def inventory(model: Any, api: Any) -> list[dict[str, Any]]:
    known = {
        v.name: v
        for v in [*model.graph.input, *model.graph.value_info, *model.graph.output]
    }
    result = []
    for index, node in enumerate(model.graph.node):
        for slot, name in enumerate(node.output):
            if not name:
                continue
            info = known.get(name)
            tensor = info.type.tensor_type if info is not None else None
            shape = (
                [
                    d.dim_value if d.HasField("dim_value") else None
                    for d in tensor.shape.dim
                ]
                if tensor is not None and tensor.HasField("shape")
                else None
            )
            element = tensor.elem_type if tensor is not None else 0
            eligible = (
                element == api.TensorProto.FLOAT
                and shape is not None
                and 1 <= len(shape) <= 8
                and all(d is None or d > 0 for d in shape)
            )
            result.append(
                {
                    "node_index": index,
                    "node_name": node.name,
                    "operator": node.op_type,
                    "inputs": list(node.input),
                    "output_index": slot,
                    "tensor": name,
                    "element_type": element,
                    "shape": shape,
                    "replayable_float": eligible,
                }
            )
    return result


def expose(model: Any, api: Any, name: str) -> dict[str, Any]:
    matches = [entry for entry in inventory(model, api) if entry["tensor"] == name]
    if len(matches) != 1 or not matches[0]["replayable_float"]:
        raise ValueError(
            "Select exactly one known top-level float tensor with a usable rank"
        )
    known = {v.name: v for v in [*model.graph.value_info, *model.graph.output]}
    selected = known[name]
    retained = [v for v in model.graph.output if v.name != name]
    model.graph.ClearField("output")
    model.graph.output.extend([selected, *retained])
    api.checker.check_model(model)
    return matches[0]


def run(args: argparse.Namespace) -> None:
    api, model, receipt = load(args.model, args.model_sha256)
    if args.command == "inventory":
        receipt["tensors"] = inventory(model, api)
        with args.output.open("x", encoding="utf-8") as stream:
            json.dump(receipt, stream, indent=2)
            stream.write("\n")
        return
    before = graph_bytes(model)
    receipt["selected_tensor"] = expose(model, api, args.tensor)
    if graph_bytes(model) != before:
        raise ValueError("Exposing an output changed nodes or initializer bytes")
    raw = model.SerializeToString(deterministic=True)
    receipt["diagnostic_model_sha256"] = hashlib.sha256(raw).hexdigest()
    receipt["diagnostic_model_bytes"] = len(raw)
    if (
        hashlib.sha256(args.model.read_bytes()).hexdigest()
        != receipt["original_model_sha256"]
    ):
        raise ValueError("Original model changed during preparation")
    args.output.mkdir()
    with (args.output / "model.onnx").open("xb") as stream:
        stream.write(raw)
    with (args.output / "manifest.json").open("x", encoding="utf-8") as stream:
        json.dump(receipt, stream, indent=2)
        stream.write("\n")


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("inventory", "expose"):
        child = commands.add_parser(command)
        child.add_argument("model", type=Path)
        child.add_argument("--model-sha256", required=True)
        if command == "expose":
            child.add_argument("--tensor", required=True)
        child.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


if __name__ == "__main__":
    run(arguments())
