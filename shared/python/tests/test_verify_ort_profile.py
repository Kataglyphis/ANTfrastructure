#!/usr/bin/env python3
"""Exercise the GPU proof against real ORT event shapes and misleading profiles."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "verify_ort_profile.py"


class ProfileTest(unittest.TestCase):
    def run_profile(self, profile: object, device: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as work:
            path = Path(work) / "profile.json"
            path.write_text(json.dumps(profile), encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(SCRIPT), str(path), "--device", device],
                capture_output=True,
                text=True,
                check=False,
            )

    def test_real_node_event_requires_the_requested_provider(self) -> None:
        profile = [
            {"cat": "Node", "args": {"provider": "CPUExecutionProvider"}},
            {"cat": "Node", "args": {"provider": "MIGraphXExecutionProvider"}},
        ]
        self.assertEqual(self.run_profile(profile, "cpu").returncode, 0)
        self.assertEqual(self.run_profile(profile, "migraphx").returncode, 0)
        self.assertNotEqual(self.run_profile(profile, "cuda").returncode, 0)
        self.assertNotEqual(self.run_profile(profile, "directml").returncode, 0)

    def test_registration_event_alone_does_not_prove_inference(self) -> None:
        profile = [{"cat": "Session", "args": {"provider": "CUDAExecutionProvider"}}]
        self.assertNotEqual(self.run_profile(profile, "cuda").returncode, 0)

    def test_wrong_top_level_and_empty_nodes_fail(self) -> None:
        self.assertNotEqual(self.run_profile({}, "cuda").returncode, 0)
        self.assertNotEqual(self.run_profile([{"cat": "Node", "args": None}], "cuda").returncode, 0)


if __name__ == "__main__":
    unittest.main()
