#!/usr/bin/env python3
"""Exercise detector parity, including score and geometry guard mutations."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "compare_detector_parity.py"


class DetectionParityTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cpu = self.root / "cpu.json"
        self.gpu = self.root / "gpu.json"
        self.reference: dict[str, Any] = {
            "schema_version": 1,
            "width": 100,
            "height": 100,
            "detections": [
                {"class": 15, "score": 0.9, "box": [10, 60, 30, 95]},
                {"class": 15, "score": 0.7, "box": [50, 20, 80, 60]},
            ],
        }
        self.cpu.write_text(json.dumps(self.reference))
        self.gpu.write_text(json.dumps(self.reference))

    def run_compare(
        self, script: Path = SCRIPT, *, pairwise: bool = False
    ) -> subprocess.CompletedProcess[str]:
        arguments = [sys.executable, "-I", str(script), str(self.cpu), str(self.gpu)]
        if pairwise:
            arguments.append("--pairwise")
        return subprocess.run(
            arguments,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_matching_reordered_detections_and_small_changes_pass(self) -> None:
        changed = json.loads(json.dumps(self.reference))
        changed["detections"][0]["score"] = 0.86
        changed["detections"][0]["box"][0] += 1
        changed["detections"].reverse()
        self.gpu.write_text(json.dumps(changed))
        result = self.run_compare()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_mismatches_and_empty_results_fail(self) -> None:
        for kind in (
            "empty",
            "class",
            "score",
            "box",
            "extra",
            "dimensions",
            "nonfinite",
            "degenerate",
        ):
            with self.subTest(kind=kind):
                changed = json.loads(json.dumps(self.reference))
                if kind == "empty":
                    changed["detections"] = []
                elif kind == "class":
                    changed["detections"][0]["class"] = 16
                elif kind == "score":
                    changed["detections"][0]["score"] = 0.8
                elif kind == "box":
                    changed["detections"][0]["box"][0] = 20
                elif kind == "extra":
                    changed["detections"].append(changed["detections"][0])
                elif kind == "dimensions":
                    changed["width"] += 1
                elif kind == "nonfinite":
                    changed["detections"][0]["score"] = float("nan")
                elif kind == "degenerate":
                    changed["detections"][0]["box"][2] = 10
                self.gpu.write_text(json.dumps(changed))
                self.assertNotEqual(self.run_compare().returncode, 0)
                self.assertNotEqual(self.run_compare(pairwise=True).returncode, 0)

    def test_pairwise_comparison_does_not_reapply_cpu_only_oracle(self) -> None:
        first = json.loads(json.dumps(self.reference))
        first["detections"][0]["score"] = 0.78
        second = json.loads(json.dumps(first))
        second["detections"][0]["score"] = 0.76
        self.cpu.write_text(json.dumps(first))
        self.gpu.write_text(json.dumps(second))
        self.assertNotEqual(self.run_compare().returncode, 0)
        result = self.run_compare(pairwise=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        second["detections"][0]["score"] = 0.70
        self.gpu.write_text(json.dumps(second))
        self.assertNotEqual(self.run_compare(pairwise=True).returncode, 0)

    def test_pairwise_still_requires_distinct_one_to_one_matches(self) -> None:
        first = json.loads(json.dumps(self.reference))
        first["detections"][0]["score"] = 0.78
        second = json.loads(json.dumps(first))
        second["detections"][1] = dict(second["detections"][0])
        self.cpu.write_text(json.dumps(first))
        self.gpu.write_text(json.dumps(second))
        self.assertNotEqual(self.run_compare(pairwise=True).returncode, 0)

    def test_cpu_must_find_both_cats_and_reject_duplicate_json_keys(self) -> None:
        self.cpu.write_text(
            json.dumps(
                {**self.reference, "detections": self.reference["detections"][:1]}
            )
        )
        self.assertNotEqual(self.run_compare().returncode, 0)
        duplicate = {
            **self.reference,
            "detections": [self.reference["detections"][0]] * 2,
        }
        self.cpu.write_text(json.dumps(duplicate))
        self.gpu.write_text(json.dumps(duplicate))
        self.assertNotEqual(self.run_compare().returncode, 0)
        self.cpu.write_text(
            '{"schema_version":1,"schema_version":1,"width":100,"height":100,"detections":[]}'
        )
        self.assertNotEqual(self.run_compare().returncode, 0)

    def test_observed_cpu_and_migraphx_cat_mismatch_is_rejected(self) -> None:
        cpu = {
            "schema_version": 1,
            "width": 640,
            "height": 640,
            "detections": [
                {"class": 15, "score": 0.88705, "box": [0.37, 227.36, 629.43, 624.89]},
                {"class": 15, "score": 0.28809, "box": [14.13, 1.08, 414.86, 375.12]},
            ],
        }
        gpu = {
            "schema_version": 1,
            "width": 640,
            "height": 640,
            "detections": [
                {"class": 15, "score": 0.6525, "box": [1.14, 246.12, 623.04, 597.9]},
                {"class": 15, "score": 0.31868, "box": [7.85, 13.19, 418.32, 589.3]},
            ],
        }
        self.cpu.write_text(json.dumps(cpu))
        self.gpu.write_text(json.dumps(cpu))
        self.assertEqual(self.run_compare().returncode, 0)
        self.gpu.write_text(json.dumps(gpu))
        self.assertNotEqual(self.run_compare().returncode, 0)

    def test_score_and_geometry_guard_mutants_are_detected(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        mutants = (
            ('abs(item["score"] - other["score"]) <= MAX_SCORE_DELTA', "True", "score"),
            ('iou(item["box"], other["box"]) >= MIN_IOU', "True", "box"),
        )
        for original, replacement, field in mutants:
            with self.subTest(field=field):
                self.assertIn(original, source)
                mutant = self.root / f"{field}-mutant.py"
                mutant.write_text(source.replace(original, replacement, 1))
                changed = json.loads(json.dumps(self.reference))
                if field == "score":
                    changed["detections"][0]["score"] = 0.8
                else:
                    changed["detections"][0]["box"][0] = 20
                self.gpu.write_text(json.dumps(changed))
                self.assertNotEqual(self.run_compare().returncode, 0)
                self.assertEqual(self.run_compare(mutant).returncode, 0)


if __name__ == "__main__":
    unittest.main()
