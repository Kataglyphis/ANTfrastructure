#!/usr/bin/env python3
"""Prepare an independent zero-pad/negative-MaxPool diagnostic, not original-model acceptance."""

import argparse
import hashlib
import importlib
import json
import struct
from pathlib import Path


def prepare(output: Path) -> None:
    api = importlib.import_module("onnx")
    shape = [1, 1, 2, 2]
    graph = api.helper.make_graph(
        [
            api.helper.make_node("Pad", ["X", "pads"], ["padded"], mode="constant"),
            api.helper.make_node(
                "MaxPool",
                ["padded"],
                ["Y"],
                kernel_shape=[2, 2],
                strides=[1, 1],
                pads=[0, 0, 0, 0],
                ceil_mode=1,
            ),
        ],
        "independent_zero_pad_maxpool",
        [api.helper.make_tensor_value_info("X", api.TensorProto.FLOAT, shape)],
        [
            api.helper.make_tensor_value_info("Y", api.TensorProto.FLOAT, shape),
            api.helper.make_tensor_value_info(
                "padded", api.TensorProto.FLOAT, [1, 1, 3, 3]
            ),
        ],
        initializer=[
            api.helper.make_tensor(
                "pads", api.TensorProto.INT64, [8], [0, 0, 0, 0, 0, 0, 1, 1]
            )
        ],
    )
    model = api.helper.make_model(
        graph, ir_version=10, opset_imports=[api.helper.make_opsetid("", 18)]
    )
    api.checker.check_model(model)
    payloads = {
        "model.onnx": model.SerializeToString(deterministic=True),
        "input.f32le": struct.pack("<4f", -1, -2, -3, -4),
        "expected.f32le": struct.pack("<4f", -1, 0, 0, 0),
    }
    output.mkdir()
    for name, data in payloads.items():
        with (output / name).open("xb") as stream:
            stream.write(data)
    manifest = {
        "schema_version": 1,
        "onnx_version": api.__version__,
        "shape": shape,
        "sha256": {
            name: hashlib.sha256(data).hexdigest() for name, data in payloads.items()
        },
        "scope": "Independent padding-contract fixture only; zero padding participates in MaxPool. Not the original detector, a package or GPU acceptance.",
    }
    with (output / "manifest.json").open("x", encoding="utf-8") as stream:
        json.dump(manifest, stream, indent=2)
        stream.write("\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    prepare(parser.parse_args().output)
