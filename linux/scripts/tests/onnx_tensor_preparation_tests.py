"""Schema doubles check planning/refusals; actual ONNX parsing, execution and GPU coverage remain separate."""

import argparse
import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace as NS
from typing import Any
from unittest import mock

g = globals()["g"]


class Record(NS):
    def SerializeToString(self, *, deterministic: bool) -> bytes:
        if not deterministic:
            raise ValueError("Fixture requires deterministic serialization")
        return self.serial


class Graph(NS):
    def ClearField(self, name: str) -> None:
        if name != "output":
            raise ValueError("Only outputs may change")
        self.output.clear()


class Model(NS):
    def SerializeToString(self, *, deterministic: bool) -> bytes:
        return json.dumps(
            {
                "outputs": [v.name for v in self.graph.output],
                "nodes": [
                    n.SerializeToString(deterministic=deterministic).decode()
                    for n in self.graph.node
                ],
            }
        ).encode()


def value(name: str, shape: list[int | None] | None, element: int = 1) -> NS:
    dimensions = [
        NS(
            dim_value=d or 0,
            HasField=lambda key, d=d: key == "dim_value" and d is not None,
        )
        for d in shape or []
    ]
    tensor = NS(
        elem_type=element,
        shape=NS(dim=dimensions),
        HasField=lambda key: key == "shape" and shape is not None,
    )
    return NS(name=name, type=NS(tensor_type=tensor))


class OnnxTensorPreparationTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.path = self.root / "original.onnx"
        self.raw = b"independent schema fixture, not an ONNX protobuf"
        self.path.write_bytes(self.raw)
        self.expected = hashlib.sha256(self.raw).hexdigest()
        self.weight = Record(
            serial=b"unchanged-weight", external_data=[], data_location=0
        )
        self.model = Model(
            functions=[],
            graph=Graph(
                sparse_initializer=[],
                initializer=[self.weight],
                input=[value("x", [2])],
                output=[value("y", [2])],
                value_info=[value("middle", [2])],
                node=[
                    Record(
                        serial=b"Relu(x)->middle",
                        name="first",
                        op_type="Relu",
                        input=["x"],
                        output=["middle"],
                        attribute=[],
                    ),
                    Record(
                        serial=b"Add(middle,w)->y",
                        name="second",
                        op_type="Add",
                        input=["middle", "w"],
                        output=["y"],
                        attribute=[],
                    ),
                ],
            ),
        )
        self.api = NS(
            __version__="fixture-version",
            TensorProto=NS(FLOAT=1, EXTERNAL=1),
            AttributeProto=NS(GRAPH=5, GRAPHS=10, SPARSE_TENSOR=11, SPARSE_TENSORS=12),
            load_model_from_string=mock.Mock(return_value=self.model),
            checker=NS(check_model=mock.Mock()),
            shape_inference=NS(
                infer_shapes=mock.Mock(
                    side_effect=lambda model, **_kwargs: copy.deepcopy(model)
                )
            ),
        )
        patch = mock.patch.object(g.importlib, "import_module", return_value=self.api)
        patch.start()
        self.addCleanup(patch.stop)

    def args(
        self, command: str, output: Path, tensor: str = "middle"
    ) -> argparse.Namespace:
        return argparse.Namespace(
            command=command,
            model=self.path,
            model_sha256=self.expected,
            output=output,
            tensor=tensor,
        )

    def test_inventory_binds_original_and_records_topological_metadata(self) -> None:
        output = self.root / "inventory.json"
        g.run(self.args("inventory", output))
        data = json.loads(output.read_text())
        self.assertEqual(data["original_model_sha256"], self.expected)
        self.assertEqual(data["original_model_bytes"], len(self.raw))
        self.assertEqual(data["original_outputs"], ["y"])
        self.assertFalse(data["acceptance"])
        self.assertIn("alter fusion", data["scope"])
        self.assertEqual(
            [(t["node_index"], t["tensor"], t["operator"]) for t in data["tensors"]],
            [(0, "middle", "Relu"), (1, "y", "Add")],
        )
        self.assertEqual(data["tensors"][0]["shape"], [2])
        self.api.shape_inference.infer_shapes.assert_called_once_with(
            self.model, check_type=True, strict_mode=True, data_prop=True
        )
        self.assertEqual(self.api.checker.check_model.call_count, 1)

    def test_expose_keeps_original_outputs_nodes_weights_and_source_bytes(self) -> None:
        output = self.root / "cut"
        before = g.graph_bytes(self.model)
        g.run(self.args("expose", output))
        document = json.loads((output / "manifest.json").read_text())
        raw = (output / "model.onnx").read_bytes()
        self.assertEqual(
            document["diagnostic_model_sha256"], hashlib.sha256(raw).hexdigest()
        )
        self.assertEqual(document["diagnostic_model_bytes"], len(raw))
        self.assertEqual(json.loads(raw)["outputs"], ["middle", "y"])
        self.assertEqual(document["selected_tensor"]["tensor"], "middle")
        self.assertFalse(document["acceptance"])
        self.assertEqual(g.graph_bytes(self.model), before)
        self.assertEqual([v.name for v in self.model.graph.output], ["y"])
        self.assertEqual(self.path.read_bytes(), self.raw)
        self.assertEqual(self.api.checker.check_model.call_count, 2)

    def test_replaying_an_original_output_does_not_duplicate_it(self) -> None:
        g.expose(self.model, self.api, "y")
        self.assertEqual([v.name for v in self.model.graph.output], ["y"])

    def test_refuse_missing_duplicate_and_unusable_tensor_before_allocating(
        self,
    ) -> None:
        for name in ("absent", "x", "w"):
            with (
                self.subTest(name=name),
                self.assertRaisesRegex(ValueError, "exactly one"),
            ):
                g.run(self.args("expose", self.root / name, name))
            self.assertFalse((self.root / name).exists())
        self.model.graph.node[1].output.append("middle")
        with self.assertRaisesRegex(ValueError, "exactly one"):
            g.expose(self.model, self.api, "middle")

    def test_float_rank_and_dimension_selection_is_explicit(self) -> None:
        cases: list[tuple[list[int | None] | None, int, bool]] = [
            ([2], 7, False),
            (None, 1, False),
            ([], 1, False),
            ([1] * 9, 1, False),
            ([0, 2], 1, False),
            ([-1], 1, False),
            ([None, 2], 1, True),
        ]
        for shape, element, allowed in cases:
            with self.subTest(shape=shape, element=element):
                self.model.graph.value_info = [value("middle", shape, element)]
                entries = g.inventory(self.model, self.api)
                self.assertEqual(entries[0]["replayable_float"], allowed)
                if not allowed:
                    with self.assertRaisesRegex(ValueError, "exactly one"):
                        g.expose(self.model, self.api, "middle")

    def test_hash_syntax_mismatch_symlink_empty_and_missing_model_refuse(self) -> None:
        for expected in ("", "ABC", self.expected.upper(), "0" * 64):
            with self.subTest(expected=expected), self.assertRaises(ValueError):
                g.load(self.path, expected)
        linked = self.root / "linked"
        linked.symlink_to(self.path)
        for path in (linked, self.root / "absent"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                g.load(path, self.expected)
        self.path.write_bytes(b"")
        with self.assertRaises(ValueError):
            g.load(self.path, hashlib.sha256(b"").hexdigest())
        self.api.load_model_from_string.assert_not_called()

    def test_external_data_local_functions_and_sparse_initializers_refuse(self) -> None:
        for attribute, replacement in (
            ("external_data", ["location"]),
            ("data_location", 1),
        ):
            original = getattr(self.weight, attribute)
            setattr(self.weight, attribute, replacement)
            with self.assertRaisesRegex(ValueError, "External tensor"):
                g.require_supported(self.model, self.api)
            setattr(self.weight, attribute, original)
        for target, attribute in (
            (self.model, "functions"),
            (self.model.graph, "sparse_initializer"),
        ):
            setattr(target, attribute, [object()])
            with self.assertRaisesRegex(ValueError, "Local functions"):
                g.require_supported(self.model, self.api)
            setattr(target, attribute, [])

    def test_nested_sparse_and_attribute_external_payloads_refuse(self) -> None:
        for kind in (5, 10, 11, 12):
            self.model.graph.node[0].attribute = [
                NS(type=kind, t=self.weight, tensors=[])
            ]
            with self.assertRaisesRegex(ValueError, "Nested graphs"):
                g.require_supported(self.model, self.api)
        self.model.graph.node[0].attribute = [NS(type=4, t=self.weight, tensors=[])]
        self.weight.external_data = ["location"]
        with self.assertRaisesRegex(ValueError, "External tensor"):
            g.require_supported(self.model, self.api)

    def test_inference_checker_and_node_or_weight_changes_are_fatal(self) -> None:
        self.api.checker.check_model.side_effect = ValueError("invalid model fixture")
        with self.assertRaisesRegex(ValueError, "invalid model"):
            g.load(self.path, self.expected)
        self.api.checker.check_model.side_effect = None
        self.api.shape_inference.infer_shapes.side_effect = ValueError(
            "inference fixture"
        )
        with self.assertRaisesRegex(ValueError, "inference fixture"):
            g.load(self.path, self.expected)
        for target in ("node", "initializer"):
            changed = copy.deepcopy(self.model)
            getattr(changed.graph, target)[0].serial = b"changed"
            self.api.shape_inference.infer_shapes.side_effect = None
            self.api.shape_inference.infer_shapes.return_value = changed
            with self.assertRaisesRegex(ValueError, "changed nodes"):
                g.load(self.path, self.expected)

    def test_existing_inventory_and_output_preserve_bytes(self) -> None:
        output = self.root / "keep"
        output.write_bytes(b"preserve")
        for command in ("inventory", "expose"):
            with self.subTest(command=command), self.assertRaises(FileExistsError):
                g.run(self.args(command, output))
            self.assertEqual(output.read_bytes(), b"preserve")

    def test_original_change_during_preparation_refuses_before_writing(self) -> None:
        def alter_original(_model: Any) -> None:
            self.path.write_bytes(b"changed original")

        self.api.checker.check_model.side_effect = alter_original
        with self.assertRaisesRegex(ValueError, "Original model changed"):
            g.run(self.args("expose", self.root / "changed"))
        self.assertFalse((self.root / "changed").exists())

    def test_large_model_refuses_before_read_or_backend_import(self) -> None:
        with (
            mock.patch.object(Path, "is_symlink", return_value=False),
            mock.patch.object(Path, "is_file", return_value=True),
            mock.patch.object(Path, "stat", return_value=NS(st_size=1024**3 + 1)),
            self.assertRaisesRegex(ValueError, "bounded regular"),
        ):
            g.load(self.path, self.expected)
        self.api.load_model_from_string.assert_not_called()

    def test_expose_checker_failure_and_node_changes_leave_no_artifacts(self) -> None:
        count = 0

        def alter_second(model: Any) -> None:
            nonlocal count
            count += 1
            if count == 2:
                model.graph.node[0].serial = b"changed by checker"

        self.api.checker.check_model.side_effect = alter_second
        with self.assertRaisesRegex(ValueError, "changed nodes"):
            g.run(self.args("expose", self.root / "altered"))
        self.assertFalse((self.root / "altered").exists())

    def test_empty_existing_output_directory_is_refused(self) -> None:
        output = self.root / "existing-directory"
        output.mkdir()
        with self.assertRaises(FileExistsError):
            g.run(self.args("expose", output))
        self.assertEqual(list(output.iterdir()), [])

    def test_new_payload_file_still_refuses_unexpected_existing_bytes(self) -> None:
        original_mkdir = Path.mkdir
        output = self.root / "new-output"

        def populated_directory(path: Path, *args: Any, **kwargs: Any) -> None:
            original_mkdir(path, *args, **kwargs)
            if path == output:
                (path / "model.onnx").write_bytes(b"preserve concurrent evidence")

        with (
            mock.patch.object(Path, "mkdir", populated_directory),
            self.assertRaises(FileExistsError),
        ):
            g.run(self.args("expose", output))
        self.assertEqual(
            (output / "model.onnx").read_bytes(), b"preserve concurrent evidence"
        )
        self.assertFalse((output / "manifest.json").exists())


if __name__ == "__main__":
    unittest.main()
