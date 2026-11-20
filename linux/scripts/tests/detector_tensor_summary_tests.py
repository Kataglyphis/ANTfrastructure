"""Independent float/metadata fixtures; no actual model, provider or package acceptance."""

import hashlib
import json
import math
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Callable
from pathlib import Path
from typing import Any

g = globals()["g"]


class TensorSummaryTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.cpu, self.gpu = self.root / "cpu", self.root / "gpu"
        for directory, output in (
            (self.cpu, [1, 2, 3, 4, 5, 6]),
            (self.gpu, [1, 2.5, 3, 4, 5, 5]),
        ):
            directory.mkdir()
            for run in (1, 2):
                document = {"schema_version": 1, "run": run}
                for kind, shape, values in (
                    ("input", [1, 3, 1, 1], [0, 1, 2]),
                    ("output", [1, 2, 3], output),
                ):
                    name = f"run-{run}-{kind}.f32le"
                    (directory / name).write_bytes(
                        struct.pack("<" + "f" * len(values), *values)
                    )
                    document[kind] = {
                        "path": name,
                        "shape": shape,
                        "dtype": "float32",
                        "byte_order": "little",
                    }
                (directory / f"run-{run}.json").write_text(json.dumps(document))

    def change_metadata(
        self, directory: Path, run: int, action: Callable[[dict[str, Any]], None]
    ) -> None:
        path = directory / f"run-{run}.json"
        data = json.loads(path.read_text())
        action(data)
        path.write_text(json.dumps(data))

    def test_exact_inputs_all_cross_pairs_and_independent_statistics(self) -> None:
        result = g.summarize(self.cpu, self.gpu, 2)
        self.assertFalse(result["acceptance"])
        self.assertEqual(
            result["identical_input_sha256"],
            hashlib.sha256(struct.pack("<3f", 0, 1, 2)).hexdigest(),
        )
        self.assertTrue(result["cpu_repeated_output_bytes_identical"])
        self.assertTrue(result["gpu_repeated_output_bytes_identical"])
        self.assertEqual(
            [(p["cpu_run"], p["gpu_run"]) for p in result["cross_pairs"]],
            [(1, 1), (1, 2), (2, 1), (2, 2)],
        )
        for pair in result["cross_pairs"]:
            self.assertEqual(pair["different_elements"], 2)
            self.assertEqual(pair["max_absolute_difference"], 1)
            self.assertEqual(pair["mean_absolute_difference"], 0.25)
            self.assertAlmostEqual(pair["rms_difference"], math.sqrt(1.25 / 6))
            self.assertEqual(pair["largest_differences"][0]["index"], [0, 1, 2])
            self.assertEqual(pair["axis_max_absolute_difference"]["2"], [0, 0.5, 1])

    def test_equal_outputs_and_observable_repeat_variance(self) -> None:
        raw = (self.cpu / "run-1-output.f32le").read_bytes()
        (self.gpu / "run-1-output.f32le").write_bytes(raw)
        result = g.summarize(self.cpu, self.gpu, 2)
        self.assertFalse(result["gpu_repeated_output_bytes_identical"])
        self.assertEqual(result["cross_pairs"][0]["largest_differences"], [])
        self.assertEqual(result["cross_pairs"][0]["different_elements"], 0)

    def test_every_repeated_input_must_match_before_provider_comparison(self) -> None:
        (self.gpu / "run-2-input.f32le").write_bytes(struct.pack("<3f", 0, 1, 3))
        with self.assertRaisesRegex(ValueError, "input bytes/shapes differ"):
            g.summarize(self.cpu, self.gpu, 2)

    def test_input_and_output_shapes_remain_bound(self) -> None:
        for kind, shape in (("input", [3]), ("output", [1, 3, 2])):
            with self.subTest(kind=kind):
                original = (self.gpu / "run-2.json").read_text()
                self.change_metadata(
                    self.gpu,
                    2,
                    lambda data, kind=kind, shape=shape: data[kind].update(shape=shape),
                )
                with self.assertRaisesRegex(ValueError, "shapes differ"):
                    g.summarize(self.cpu, self.gpu, 2)
                (self.gpu / "run-2.json").write_text(original)

    def test_schema_and_run_types_cannot_accept_booleans(self) -> None:
        for key, value in (("schema_version", True), ("run", True), ("run", 2)):
            original = (self.cpu / "run-1.json").read_text()
            self.change_metadata(
                self.cpu,
                1,
                lambda data, key=key, value=value: data.update({key: value}),
            )
            with self.assertRaisesRegex(ValueError, "run identity"):
                g.read_run(self.cpu, 1)
            (self.cpu / "run-1.json").write_text(original)

    def test_tensor_metadata_is_exact_and_paths_are_fixed(self) -> None:
        for values in (
            {"shape": [1, True, 3]},
            {"shape": []},
            {"shape": [0, 3]},
            {"path": "../elsewhere"},
            {"dtype": "float64"},
            {"byte_order": "big"},
        ):
            original = (self.cpu / "run-1.json").read_text()
            self.change_metadata(
                self.cpu, 1, lambda data, values=values: data["input"].update(values)
            )
            with self.assertRaises(ValueError):
                g.read_run(self.cpu, 1)
            (self.cpu / "run-1.json").write_text(original)

    def test_float_count_and_nonfinite_values_are_rejected_directly(self) -> None:
        for raw in (
            struct.pack("<2f", 0, 1),
            struct.pack("<3f", 0, math.nan, 2),
            struct.pack("<3f", 0, math.inf, 2),
        ):
            (self.cpu / "run-1-input.f32le").write_bytes(raw)
            with self.assertRaises(ValueError):
                g.read_run(self.cpu, 1)

    def test_missing_extra_and_nonregular_evidence_is_refused(self) -> None:
        extra = self.cpu / "unlisted"
        extra.write_text("extra")
        with self.assertRaisesRegex(ValueError, "roster"):
            g.read_directory(self.cpu, 2)
        extra.unlink()
        (self.cpu / "run-2.json").unlink()
        with self.assertRaisesRegex(ValueError, "roster"):
            g.read_directory(self.cpu, 2)

    def test_actual_symlinks_are_not_tensor_evidence(self) -> None:
        target = self.cpu / "run-1-input.f32le"
        original = self.root / "original"
        target.rename(original)
        target.symlink_to(original)
        with self.assertRaisesRegex(ValueError, "invalid tensor evidence file"):
            g.read_run(self.cpu, 1)
        link = self.root / "linked cpu"
        link.symlink_to(self.cpu, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "real evidence directory"):
            g.read_directory(link, 2)

    def test_duplicate_metadata_keys_and_missing_repeats_fail(self) -> None:
        path = self.cpu / "run-1.json"
        path.write_text(
            path.read_text().replace(
                '"schema_version": 1', '"schema_version": 1, "schema_version": 1'
            )
        )
        with self.assertRaisesRegex(ValueError, "duplicate JSON key"):
            g.read_run(self.cpu, 1)
        with self.assertRaises(ValueError):
            g.read_directory(self.gpu, 1)

    def test_cli_writes_diagnostic_without_acceptance_and_never_overwrites(
        self,
    ) -> None:
        output = self.root / "summary.json"
        command = [
            sys.executable,
            "-I",
            g.__file__,
            str(self.cpu),
            str(self.gpu),
            "--output",
            str(output),
        ]
        first = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertFalse(json.loads(output.read_text())["acceptance"])
        old = output.read_bytes()
        second = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertEqual(second.returncode, 1, second.stderr)
        self.assertEqual(output.read_bytes(), old)

    def test_missing_canonical_reader_fails_before_comparison(self) -> None:
        directory = self.root / "tools"
        directory.mkdir()
        script = directory / "summarize_detector_tensors.py"
        shutil.copy2(g.__file__, script)
        (directory / "compare_detector_parity.py").write_text("unique = None\n")
        result = subprocess.run(
            [
                sys.executable,
                "-I",
                str(script),
                str(self.cpu),
                str(self.gpu),
                "--output",
                str(self.root / "missing-api.json"),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("missing canonical duplicate-key reader", result.stderr)
        self.assertFalse((self.root / "missing-api.json").exists())


if __name__ == "__main__":
    unittest.main(argv=[__file__])
