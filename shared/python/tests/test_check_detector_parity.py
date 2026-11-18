#!/usr/bin/env python3
"""check_detector_parity.py against a fake detector run as a real subprocess, with the hub's real verifiers."""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
HUB = ROOT.parents[1]
sys.path.insert(0, str(ROOT))
import check_detector_parity as parity

FAKE = r"""
import json, os, pathlib, sys
out, repeat, profile = (pathlib.Path(a) for a in sys.argv[1:4])
label, device = out.stem, os.environ["KATAGLYPHIS_ORT_DEVICE"]
assert "KATAGLYPHIS_PREPROCESS" not in os.environ
assert os.environ.get("KATAGLYPHIS_ONNX_BACKEND") == os.environ.get("FAKE_WANT_BACKEND")
if os.getenv("FAKE_FAIL") == label: sys.exit(4)
doc = {"schema_version": 1, "width": 100, "height": 100, "detections": [
    {"class": 15, "score": 0.9, "box": [10, 60, 30, 95]},
    {"class": 15, "score": 0.7, "box": [50, 20, 80, 60]}]}
if os.getenv("FAKE_MISMATCH") == label: doc["detections"][0]["score"] = 0.4
out.write_text(json.dumps(doc))
if os.getenv("FAKE_NO_REPEAT") != label: repeat.write_text(json.dumps(doc))
provider = {"cpu": "CPUExecutionProvider", "cuda": "CUDAExecutionProvider", "directml": "DmlExecutionProvider"}[device]
if os.getenv("FAKE_FALLBACK") == label: provider = "CPUExecutionProvider"
events = []
for n in range(2):
    events.append({"cat": "Session", "name": "model_run", "pid": 1, "tid": 1, "ts": n * 100, "dur": 90, "ph": "X"})
    events.append({"cat": "Node", "name": "conv", "pid": 1, "tid": 1, "ts": n * 100 + 10, "dur": 20, "ph": "X",
                   "args": {"provider": provider, "op_name": "Conv"}})
pathlib.Path(str(profile) + ".json").write_text(json.dumps(events))
"""


def run(command: list[str], cwd: Path | None = None, env: dict[str, str] | None = None) -> None:
    subprocess.run(command, check=True, cwd=cwd, env=env)


class Inputs(unittest.TestCase):
    def test_only_a_gpu_provider_and_a_plain_adapter_index(self) -> None:
        parity.validate_device("cuda", "0")
        parity.validate_device("directml", "2147483647")
        for device, index in (("cpu", "0"), ("directml", "01"), ("directml", "-1"),
                              ("directml", "2147483648"), ("directml", "1 ")):
            with self.subTest(device=device, index=index), self.assertRaises(ValueError):
                parity.validate_device(device, index)

    def test_the_photo_digest_and_the_packaged_runtime(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            stage = Path(temp)
            photo = stage / "two_cats.jpg"
            photo.write_bytes(b"not the photo")
            with self.assertRaises(ValueError):
                parity.verify_fixture(photo)
            with self.assertRaisesRegex(ValueError, "missing"):
                parity.verify_runtime(stage)
            outside = stage / "elsewhere"
            outside.mkdir()
            (outside / "onnxruntime.dll").write_text("x")
            (stage / "onnxruntime.dll").symlink_to(outside / "onnxruntime.dll")
            with self.assertRaisesRegex(ValueError, "escapes"):
                parity.verify_runtime(stage)
            (stage / "onnxruntime.dll").unlink()
            (stage / "onnxruntime.dll").write_text("x")
            self.assertEqual(parity.verify_runtime(stage), stage / "onnxruntime.dll")

    def test_no_inherited_override_reaches_a_child(self) -> None:
        stage = Path("stage")
        poisoned = {"KATAGLYPHIS_PREPROCESS": "x", "ORT_LIB_LOCATION": "x", "MIGRAPHX_X": "x",
                    "GST_PLUGIN_PATH": "x", "kataglyphis_lower": "x", "SYSTEMROOT": "C:\\Windows"}
        with patch.dict(os.environ, poisoned):
            gpu = parity.child_environment(stage, "directml", "3", {"KATAGLYPHIS_ONNX_BACKEND": "ort"})
            cpu = parity.child_environment(stage, "cpu", "3")
        for name in ("KATAGLYPHIS_PREPROCESS", "ORT_LIB_LOCATION", "MIGRAPHX_X", "GST_PLUGIN_PATH",
                     "kataglyphis_lower"):
            self.assertNotIn(name, gpu)
        self.assertEqual(gpu["KATAGLYPHIS_DIRECTML_DEVICE_ID"], "3")
        self.assertEqual(gpu["KATAGLYPHIS_ONNX_BACKEND"], "ort")
        self.assertEqual(gpu["ORT_DYLIB_PATH"], str(stage / "onnxruntime.dll"))
        self.assertNotIn("KATAGLYPHIS_DIRECTML_DEVICE_ID", cpu)
        self.assertNotIn("KATAGLYPHIS_ONNX_BACKEND", cpu, "a consumer's extra is passed per call")

    def test_only_directml_checks_the_adapter(self) -> None:
        calls = []
        with tempfile.TemporaryDirectory() as temp:
            hub = Path(temp)
            parity.verify_adapter(hub, "cuda", "0", calls.append)
            self.assertEqual(calls, [])
            with self.assertRaisesRegex(ValueError, "DXGI"):
                parity.verify_adapter(hub, "directml", "0", calls.append)
            dxgi = hub / parity.DXGI
            dxgi.parent.mkdir(parents=True)
            dxgi.write_text("")
            parity.verify_adapter(hub, "directml", "3", calls.append)
        self.assertEqual(calls[0][-4:], ["--vendor", "amd", "--index", "3"])


class Parity(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.fake = self.root / "fake.py"
        self.fake.write_text(FAKE)

    def check(self, device: str = "directml", extra: dict[str, str] | None = None) -> Path:
        work = parity.new_work("parity-", self.root)

        def launch(label: str, output: Path, repeat: Path, profile: Path) -> list[str]:
            return [sys.executable, "-I", str(self.fake), str(output), str(repeat), str(profile)]

        return parity.check_parity(HUB, self.root, device, "3", work, launch, run, extra)

    def test_three_processes_each_with_one_profile_pass(self) -> None:
        for device in ("directml", "cuda"):
            work = self.check(device)
            self.assertEqual(sorted(p.name for p in work.glob("*-profile*.json")),
                             ["cpu-profile.json", "gpu1-profile.json", "gpu2-profile.json"])
        with patch.dict(os.environ, {"FAKE_WANT_BACKEND": "ort"}):
            self.check(extra={"KATAGLYPHIS_ONNX_BACKEND": "ort"})

    def test_a_failure_fallback_mismatch_or_missing_repeat_blocks(self) -> None:
        for flag in ("FAKE_FAIL", "FAKE_FALLBACK", "FAKE_MISMATCH", "FAKE_NO_REPEAT"):
            for label in ("gpu1", "gpu2"):
                with (self.subTest(flag=flag, label=label), patch.dict(os.environ, {flag: label}),
                      self.assertRaises((ValueError, subprocess.SubprocessError))):
                    self.check()

    def test_a_missing_pinned_verifier_fails_before_any_run(self) -> None:
        launched = []
        with self.assertRaisesRegex(ValueError, "pinned helper missing"):
            parity.check_parity(self.root, self.root, "cuda", "0", self.root,
                                lambda *a: launched.append(a) or [], run)
        self.assertEqual(launched, [])


if __name__ == "__main__":
    unittest.main()
