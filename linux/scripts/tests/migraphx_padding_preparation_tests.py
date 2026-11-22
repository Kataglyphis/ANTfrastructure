"""Schema doubles prove fixture identity and refusals, not ONNX validity or GPU inference."""

import hashlib
import json
import runpy
import struct
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


class PaddingPreparationTests(unittest.TestCase):
    """The negative fixture and its independently expected bytes must stay fixed."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.output = Path(temporary.name) / "fixture"
        self.prepare = runpy.run_path(str(
            Path(__file__).resolve().parents[1] / "prepare-migraphx-padding-reproducer.py"
        ))["prepare"]
        self.api = SimpleNamespace(
            __version__="schema-double", TensorProto=SimpleNamespace(FLOAT=1, INT64=7),
            helper=mock.Mock(), checker=mock.Mock(),
        )
        self.api.helper.make_model.return_value.SerializeToString.return_value = b"schema-double"
        patcher = mock.patch.object(self.prepare.__globals__["importlib"], "import_module",
                                    return_value=self.api)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_graph_identity_and_cpu_baseline_output(self) -> None:
        """Removing the padded output would restore the unsuitable first CPU baseline."""
        self.prepare(self.output)
        self.assertEqual(self.api.helper.make_node.call_args_list, [
            mock.call("Pad", ["X", "pads"], ["padded"], mode="constant"),
            mock.call("MaxPool", ["padded"], ["Y"], kernel_shape=[2, 2],
                      strides=[1, 1], pads=[0, 0, 0, 0], ceil_mode=1),
        ])
        self.assertEqual(self.api.helper.make_tensor_value_info.call_args_list, [
            mock.call("X", 1, [1, 1, 2, 2]), mock.call("Y", 1, [1, 1, 2, 2]),
            mock.call("padded", 1, [1, 1, 3, 3]),
        ])
        self.api.helper.make_tensor.assert_called_once_with(
            "pads", 7, [8], [0, 0, 0, 0, 0, 0, 1, 1])
        self.api.helper.make_opsetid.assert_called_once_with("", 18)
        self.assertEqual(self.api.helper.make_model.call_args.kwargs["ir_version"], 10)
        self.api.checker.check_model.assert_called_once_with(self.api.helper.make_model.return_value)
        self.api.helper.make_model.return_value.SerializeToString.assert_called_once_with(
            deterministic=True)

    def test_preserved_input_expected_values_and_manifest(self) -> None:
        """Expected boundary values are independent of the implementation's actual output."""
        self.prepare(self.output)
        payloads = {
            "model.onnx": b"schema-double",
            "input.f32le": struct.pack("<4f", -1, -2, -3, -4),
            "expected.f32le": struct.pack("<4f", -1, 0, 0, 0),
        }
        for name, expected in payloads.items():
            self.assertEqual((self.output / name).read_bytes(), expected)
        manifest = json.loads((self.output / "manifest.json").read_text())
        self.assertEqual(manifest["shape"], [1, 1, 2, 2])
        self.assertEqual(manifest["schema_version"], 1)
        self.assertEqual(manifest["sha256"], {
            name: hashlib.sha256(data).hexdigest() for name, data in payloads.items()
        })

    def test_existing_empty_output_refuses(self) -> None:
        """Evidence directories are new even when an existing directory is empty."""
        self.output.mkdir()
        with self.assertRaises(FileExistsError):
            self.prepare(self.output)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_checker_failure_preserves_no_artifacts(self) -> None:
        """A graph refusal cannot leave a model presented as a prepared fixture."""
        self.api.checker.check_model.side_effect = ValueError("invalid graph")
        with self.assertRaisesRegex(ValueError, "invalid graph"):
            self.prepare(self.output)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
