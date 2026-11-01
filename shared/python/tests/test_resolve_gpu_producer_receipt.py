#!/usr/bin/env python3
"""Reject stale, malformed and wrong-tuple producer metadata before CI uses it."""

from __future__ import annotations

import copy
import importlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
resolver = importlib.import_module("resolve_gpu_producer_receipt")

ENV = {
    "GITHUB_REPOSITORY": "Kataglyphis/OrchestrANT",
    "GITHUB_SHA": "a" * 40,
    "GITHUB_RUN_ID": "100",
    "GITHUB_RUN_ATTEMPT": "2",
}
GOOD: dict[str, Any] = {
    "schema_version": 1,
    "status": "passed",
    "identity": {
        "repository": ENV["GITHUB_REPOSITORY"],
        "revision": ENV["GITHUB_SHA"],
        "run_id": "100",
        "run_attempt": "2",
        "artifact_id": "37",
        "artifact_digest": "sha256:" + "b" * 64,
        "platform": "linux",
        "arch": "x64",
        "vendor": "amd",
        "check": "producer-verified",
    },
    "files": {name: "c" * 64 for name in ("one.deb", "one.tar.gz", "one.AppImage")},
}


class ProducerReceiptTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "receipt.json"
        self.env = patch.dict(os.environ, ENV)
        self.env.start()

    def tearDown(self) -> None:
        self.env.stop()
        self.temp.cleanup()

    def resolve(self, value: dict) -> dict[str, object]:
        self.path.write_text(json.dumps(value), encoding="utf-8")
        return dict(
            resolver.resolve(
                self.path, "linux", "amd", "x64", "37", "sha256:" + "b" * 64
            )
        )

    def test_correct_receipt(self) -> None:
        result = self.resolve(GOOD)
        self.assertEqual(result["artifact_id"], "37")
        self.assertEqual(result["artifact_digest"], "b" * 64)
        self.assertEqual(result["files"], ["one.AppImage", "one.deb", "one.tar.gz"])

    def test_identity_and_attempt_are_bound(self) -> None:
        for field, value in (
            ("repository", "Other/Repo"),
            ("revision", "d" * 40),
            ("run_id", "101"),
            ("run_attempt", "1"),
            ("vendor", "nvidia"),
            ("arch", "arm64"),
            ("artifact_id", "0"),
            ("artifact_digest", "bad"),
            ("check", "gpu-model-inference"),
        ):
            with self.subTest(field=field):
                value_copy = copy.deepcopy(GOOD)
                value_copy["identity"][field] = value
                with self.assertRaises(ValueError):
                    self.resolve(value_copy)

    def test_missing_extra_or_bad_packages_fail(self) -> None:
        for files in (
            {"one.deb": "c" * 64, "one.tar.gz": "c" * 64},
            GOOD["files"] | {"extra.whl": "c" * 64},
            GOOD["files"] | {"../bad.AppImage": "c" * 64},
            GOOD["files"] | {"ONE.DEB": "c" * 64},
            GOOD["files"] | {"one.deb": "not-a-hash"},
        ):
            with self.subTest(files=files):
                value_copy = copy.deepcopy(GOOD)
                value_copy["files"] = files
                with self.assertRaises(ValueError):
                    self.resolve(value_copy)

    def test_duplicate_json_and_unpassed_receipt_fail(self) -> None:
        self.path.write_text('{"status":"passed","status":"passed"}', encoding="utf-8")
        with self.assertRaises(ValueError):
            resolver.resolve(self.path, "linux", "amd", "x64", "37", "b" * 64)
        value_copy = copy.deepcopy(GOOD)
        value_copy["status"] = "failed"
        with self.assertRaises(ValueError):
            self.resolve(value_copy)

    def test_cli_outputs_only_after_validation(self) -> None:
        output = Path(self.temp.name) / "outputs"
        env = os.environ | {"GITHUB_OUTPUT": str(output)}
        command = [
            sys.executable,
            "-I",
            str(Path(resolver.__file__)),
            str(self.path),
            "--platform",
            "linux",
            "--vendor",
            "amd",
            "--arch",
            "x64",
            "--artifact-id",
            "37",
            "--artifact-digest",
            "sha256:" + "b" * 64,
        ]
        stale = copy.deepcopy(GOOD)
        stale["identity"]["run_attempt"] = "1"
        self.path.write_text(json.dumps(stale), encoding="utf-8")
        result = subprocess.run(
            command, env=env, capture_output=True, text=True, check=False
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())
        self.path.write_text(json.dumps(GOOD), encoding="utf-8")
        result = subprocess.run(
            command, env=env, capture_output=True, text=True, check=False
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        text = output.read_text(encoding="utf-8")
        self.assertIn("artifact_id=37\n", text)
        self.assertIn("artifact_digest=" + "b" * 64, text)
        self.assertIn("files<<GPU_PACKAGE_FILES\n", text)

    def test_independently_supplied_upload_identity_is_required(self) -> None:
        self.path.write_text(json.dumps(GOOD), encoding="utf-8")
        with self.assertRaises(ValueError):
            resolver.resolve(self.path, "linux", "amd", "x64", "38", "b" * 64)
        with self.assertRaises(ValueError):
            resolver.resolve(self.path, "linux", "amd", "x64", "37", "c" * 64)
        with self.assertRaisesRegex(ValueError, "Linux packages only"):
            resolver.resolve(self.path, "windows", "amd", "x64", "37", "b" * 64)


if __name__ == "__main__":
    unittest.main()
