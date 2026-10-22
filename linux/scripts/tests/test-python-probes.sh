#!/usr/bin/env bash
# Standalone probes must retain pin authority, real media checks and cross-Python metadata.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PY="${PREFLIGHT_PYTHON:-python3}"
t_case "Python probe behavior stays strict after extraction"
rc=0
"${PY}" - "${TESTS_DIR}/../06-packaging/venv-version-probe.py" \
  "${TESTS_DIR}/../03-media/build/gstreamer/common/gst-python-build-config.py" <<'PY' || rc=$?
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

VERSION_PATH, GST_PATH = sys.argv[1:]

def load(path):
    spec = importlib.util.spec_from_file_location("probe", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

class ProbeTests(unittest.TestCase):
    def setUp(self):
        self.probe = load(VERSION_PATH)

    def run_package(self, version, build_pin, locked):
        failures, tolerated = [], []
        with patch.object(self.probe, "installed_version", return_value=version):
            self.probe.check_package(("genai", "onnxruntime-genai", build_pin, False),
                                     {"onnxruntime-genai": set(locked)}, failures, tolerated)
        return failures, tolerated

    def test_build_pin_overrules_matching_lock(self):
        failures, tolerated = self.run_package("0.14.0", "0.15.2", ["0.14.0"])
        self.assertEqual(len(failures), 1)
        self.assertIn("versions.env build pin", failures[0])
        self.assertFalse(tolerated)

    def test_local_prerelease_matches_its_build_pin(self):
        failures, _ = self.run_package("0.15.2a0+git123", "0.15.2", [])
        self.assertFalse(failures)

    def test_riscv_lock_only_version_is_independent(self):
        self.probe.is_riscv64 = True
        failures, _ = self.run_package("0.16.0", "", ["0.15.2"])
        self.assertFalse(failures)

    def test_unknown_arch_cannot_inherit_a_tolerance(self):
        self.probe.ARCH = "unknown"
        self.probe.KNOWN_DRIFT = [("onnxruntime-genai", "arm64", "0.14.0", "0.15.2", "fixture")]
        failures, tolerated = self.run_package("0.14.0", "0.15.2", [])
        self.assertEqual(len(failures), 1)
        self.assertFalse(tolerated)

    def test_missing_tvm_is_fatal_when_pinned(self):
        failures = []
        with patch.dict(sys.modules, {"tvm": None}), patch.dict(os.environ, {"EXP_TVM": "0.26.0"}):
            self.probe.check_tvm(failures)
        self.assertEqual(len(failures), 1)
        self.assertIn("NOT IMPORTABLE", failures[0])

    def media_fixture(self, read_ok, write_ok):
        frame = types.SimpleNamespace(shape=(48, 64, 3), ndim=3)
        def writer(path, *args):
            Path(path).write_bytes(b"clip")
            return types.SimpleNamespace(isOpened=lambda: write_ok, write=lambda value: None,
                                         release=lambda: None)
        cv2 = types.SimpleNamespace(__version__="5.0.0", CAP_GSTREAMER=1, CAP_FFMPEG=2,
            getBuildInformation=lambda: "GStreamer: YES\nFFMPEG: YES",
            VideoCapture=lambda *args: types.SimpleNamespace(read=lambda: (read_ok, frame),
                                                            release=lambda: None),
            VideoWriter=writer, VideoWriter_fourcc=lambda *args: 1)
        numpy = types.SimpleNamespace(full=lambda *args: frame, uint8="uint8")
        return {"cv2": cv2, "numpy": numpy}

    def check_media(self, read_ok, write_ok):
        failures = []
        with patch.dict(sys.modules, self.media_fixture(read_ok, write_ok)), \
             patch.dict(os.environ, {"STV_MEDIA_FUNCTIONAL": "1", "EXP_OPENCV_MAJOR": "5"}):
            self.probe.check_cv2(failures)
        return failures

    def test_advertised_backends_must_deliver_frames(self):
        failures = self.check_media(False, True)
        self.assertTrue(any("NO frame" in value for value in failures))
        self.assertTrue(any("cannot read back" in value for value in failures))

    def test_advertised_ffmpeg_must_open_its_writer(self):
        failures = self.check_media(True, False)
        self.assertTrue(any("would not open" in value for value in failures))

    def test_functional_media_roundtrip_passes(self):
        self.assertFalse(self.check_media(True, True))

    def test_gstreamer_metadata_preserves_target_abi(self):
        module = load(GST_PATH)
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            include = root / "include" / "python"
            include.mkdir(parents=True)
            library = root / "libpython.so"
            output = root / "config.json"
            args = [GST_PATH, str(output), "aarch64-linux-gnu", str(include), str(library), "/target/pc"]
            for present in (False, True):
                if present:
                    library.touch()
                with patch.object(sys, "argv", args):
                    module.main()
                data = json.loads(output.read_text())
                self.assertEqual(data["implementation"]["_multiarch"], "aarch64-linux-gnu")
                self.assertEqual(data["c_api"]["pkgconfig_path"], "/target/pc")
                self.assertEqual("dynamic" in data["libpython"], present)
                self.assertEqual(data["base_prefix"], str(root))

    def test_gstreamer_metadata_refuses_missing_headers(self):
        module = load(GST_PATH)
        with patch.object(sys, "argv", [GST_PATH, "/unused", "target", "/no-such-headers", "/none", "/pc"]):
            with self.assertRaises(SystemExit):
                module.main()

with contextlib.redirect_stdout(io.StringIO()):
    unittest.main(argv=["probes"], verbosity=2)
PY
t_assert_eq 0 "${rc}" "Python probe regression tests must pass"
t_summary
