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
    def run_profile(
        self, profile: object, device: str, *extra: str
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as work:
            path = Path(work) / "profile.json"
            path.write_text(json.dumps(profile), encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(SCRIPT), str(path), "--device", device, *extra],
                capture_output=True,
                text=True,
                check=False,
            )

    def test_real_node_event_requires_the_requested_provider(self) -> None:
        profile = [
            {
                "cat": "Node",
                "args": {"provider": "CPUExecutionProvider", "op_name": "Conv"},
            },
            {
                "cat": "Node",
                "args": {
                    "provider": "MIGraphXExecutionProvider",
                    "op_name": "FusedGraph",
                },
            },
        ]
        self.assertEqual(self.run_profile(profile, "cpu").returncode, 0)
        self.assertEqual(self.run_profile(profile, "migraphx").returncode, 0)
        self.assertNotEqual(self.run_profile(profile, "cuda").returncode, 0)
        self.assertNotEqual(self.run_profile(profile, "directml").returncode, 0)

    def test_registration_event_alone_does_not_prove_inference(self) -> None:
        profile = [{"cat": "Session", "args": {"provider": "CUDAExecutionProvider"}}]
        self.assertNotEqual(self.run_profile(profile, "cuda").returncode, 0)

    def test_all_supported_gpu_providers_accept_fused_computation(self) -> None:
        for device, provider in (
            ("cuda", "CUDAExecutionProvider"),
            ("migraphx", "MIGraphXExecutionProvider"),
            ("directml", "DmlExecutionProvider"),
        ):
            with self.subTest(device=device):
                profile = [
                    {
                        "cat": "Node",
                        "args": {"provider": provider, "op_name": "FusedGraph"},
                    }
                ]
                self.assertEqual(self.run_profile(profile, device).returncode, 0)
                profile[0]["args"]["op_name"] = " MemcpyFromHost "
                self.assertNotEqual(self.run_profile(profile, device).returncode, 0)

    def test_cpu_accelerators_need_their_own_operators(self) -> None:
        cpu_only = [
            {
                "cat": "Node",
                "args": {"provider": "CPUExecutionProvider", "op_name": "Conv"},
            }
        ]
        for device, provider in (
            ("xnnpack", "XnnpackExecutionProvider"),
            ("dnnl", "DnnlExecutionProvider"),
        ):
            with self.subTest(device=device):
                self.assertNotEqual(self.run_profile(cpu_only, device).returncode, 0)
                profile = [
                    *cpu_only,
                    {"cat": "Node", "args": {"provider": provider, "op_name": "Conv"}},
                ]
                result = self.run_profile(profile, device)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(provider, result.stdout)

    def test_transfers_and_unidentified_nodes_are_not_gpu_computation(self) -> None:
        profile = [
            {
                "cat": "Node",
                "args": {
                    "provider": "CUDAExecutionProvider",
                    "op_name": "MemcpyFromHost",
                },
            },
            {
                "cat": "Node",
                "args": {
                    "provider": "CUDAExecutionProvider",
                    "op_name": "MemcpyToHost",
                },
            },
            {"cat": "Node", "args": {"provider": "MIGraphXExecutionProvider"}},
            {
                "cat": "Node",
                "args": {"provider": "CPUExecutionProvider", "op_name": "Conv"},
            },
        ]
        self.assertEqual(self.run_profile(profile, "cpu").returncode, 0)
        self.assertNotEqual(self.run_profile(profile, "cuda").returncode, 0)
        self.assertNotEqual(self.run_profile(profile, "migraphx").returncode, 0)

    def test_wrong_top_level_and_empty_nodes_fail(self) -> None:
        self.assertNotEqual(self.run_profile({}, "cuda").returncode, 0)
        self.assertNotEqual(
            self.run_profile([{"cat": "Node", "args": None}], "cuda").returncode, 0
        )

    def test_each_repeated_run_requires_a_gpu_model_operator(self) -> None:
        runs = [
            {
                "name": "model_run",
                "cat": "Session",
                "ph": "X",
                "pid": 1,
                "ts": start,
                "dur": 10,
            }
            for start in (10, 30)
        ]

        def node(
            start: int,
            provider: str = "CUDAExecutionProvider",
            name: str = "Conv",
            pid: int = 1,
        ) -> dict[str, object]:
            return {
                "cat": "Node",
                "ph": "X",
                "pid": pid,
                "ts": start,
                "dur": 2,
                "args": {"provider": provider, "op_name": name},
            }

        self.assertEqual(
            self.run_profile(
                runs + [node(12), node(32)], "cuda", "--min-runs", "2"
            ).returncode,
            0,
        )
        for invalid in (
            runs[:1] + [node(12)],
            runs + [node(12), node(32, provider="CPUExecutionProvider")],
            runs + [node(12), node(32, name="MemcpyFromHost")],
            runs + [node(12), node(32, pid=2)],
            runs + [node(12), {**node(32), "ph": "B"}],
            runs + [node(12), node(40)],
            runs + [node(12), {**node(32), "dur": 20}],
            [{**runs[0], "dur": 25}, runs[1], node(12), node(32)],
            [runs[0], {**runs[1], "ts": True}, node(12), node(32)],
            [runs[0], {**runs[1], "ph": "B"}, node(12), node(32)],
        ):
            with self.subTest(invalid=invalid):
                self.assertNotEqual(
                    self.run_profile(invalid, "cuda", "--min-runs", "2").returncode, 0
                )

    def test_min_runs_argument_must_be_positive(self) -> None:
        self.assertNotEqual(
            self.run_profile([], "cuda", "--min-runs", "0").returncode, 0
        )

    def test_oversized_integer_timing_fails_cleanly(self) -> None:
        run = {
            "name": "model_run",
            "cat": "Session",
            "ph": "X",
            "pid": 1,
            "ts": 10**400,
            "dur": 1,
        }
        node = {
            "cat": "Node",
            "ph": "X",
            "pid": 1,
            "ts": 0,
            "dur": 1,
            "args": {"provider": "CUDAExecutionProvider", "op_name": "Conv"},
        }
        for events in ([run, node], [{**run, "ts": 0}, {**node, "dur": 10**400}]):
            with self.subTest(events=events):
                result = self.run_profile(events, "cuda", "--min-runs", "1")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Invalid ORT profile:", result.stderr)
                self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
