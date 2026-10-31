#!/usr/bin/env python3
"""Test receipt integrity; no GPU, CI service, or authenticity proof is exercised."""

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "gpu_artifact_receipt.py"
SPEC = importlib.util.spec_from_file_location("gpu_artifact_receipt", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
RECEIPT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RECEIPT)


class ReceiptTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.packages = self.root / "packages"
        self.packages.mkdir()
        (self.packages / "app.zip").write_bytes(b"gpu package")
        (self.packages / "app.deb").write_bytes(b"gpu deb")
        self.receipt = self.root / "receipt.json"
        self.identity = {
            "repository": "Kataglyphis/Example",
            "revision": "a" * 40,
            "run-id": "42",
            "run-attempt": "2",
            "artifact-id": "31",
            "artifact-digest": "b" * 64,
            "platform": "linux",
            "arch": "x64",
            "vendor": "nvidia",
            "check": "gpu-model-inference",
        }

    def run_tool(
        self, operation: str, *extra: str, script: Path = SCRIPT
    ) -> subprocess.CompletedProcess[str]:
        command = [
            sys.executable,
            str(script),
            operation,
            "--directory",
            str(self.packages),
            "--receipt",
            str(self.receipt),
        ]
        for key, value in self.identity.items():
            command += ["--" + key, value]
        command += ["--file", "app.zip", "--file", "app.deb", *extra]
        return subprocess.run(command, capture_output=True, text=True, check=False)

    def create(self) -> None:
        result = self.run_tool("create")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_round_trip_never_overwrites_a_receipt(self) -> None:
        self.create()
        self.assertEqual(self.run_tool("verify").returncode, 0)
        self.assertNotEqual(self.run_tool("create").returncode, 0)

    def test_action_digest_and_prefixed_digest_use_the_same_canonical_value(
        self,
    ) -> None:
        self.create()
        data = json.loads(self.receipt.read_text(encoding="utf-8"))
        self.assertEqual(data["identity"]["artifact_digest"], "b" * 64)
        result = self.run_tool("verify", "--artifact-digest", "sha256:" + "b" * 64)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_all_supported_gpu_tuples_round_trip(self) -> None:
        for index, (platform, arch, vendor) in enumerate(
            (
                ("linux", "x64", "amd"),
                ("linux", "x64", "nvidia"),
                ("linux", "arm64", "nvidia"),
                ("windows", "x64", "amd"),
                ("windows", "x64", "nvidia"),
            )
        ):
            with self.subTest(platform=platform, arch=arch, vendor=vendor):
                arguments = (
                    "--receipt",
                    str(self.root / f"receipt-{index}.json"),
                    "--platform",
                    platform,
                    "--arch",
                    arch,
                    "--vendor",
                    vendor,
                )
                self.assertEqual(self.run_tool("create", *arguments).returncode, 0)
                self.assertEqual(self.run_tool("verify", *arguments).returncode, 0)

    def test_changes_missing_extra_and_directories_fail(self) -> None:
        self.create()
        package = self.packages / "app.zip"
        package.write_bytes(b"changed")
        self.assertNotEqual(self.run_tool("verify").returncode, 0)
        package.unlink()
        self.assertNotEqual(self.run_tool("verify").returncode, 0)
        package.write_bytes(b"gpu package")
        (self.packages / "extra").write_bytes(b"extra")
        self.assertNotEqual(self.run_tool("verify").returncode, 0)
        (self.packages / "extra").unlink()
        package.unlink()
        package.mkdir()
        self.assertNotEqual(self.run_tool("verify").returncode, 0)

    def test_each_ci_identity_field_is_required_to_match(self) -> None:
        self.create()
        replacements = {
            "repository": "Kataglyphis/Other",
            "revision": "b" * 40,
            "run-id": "43",
            "run-attempt": "3",
            "artifact-id": "32",
            "artifact-digest": "sha256:" + "c" * 64,
            "platform": "windows",
            "arch": "arm64",
            "vendor": "amd",
            "check": "other-check",
        }
        for field, replacement in replacements.items():
            with self.subTest(field=field):
                self.assertNotEqual(
                    self.run_tool("verify", "--" + field, replacement).returncode, 0
                )

    def test_rejects_untrusted_receipt_structure(self) -> None:
        self.create()
        original = json.loads(self.receipt.read_text(encoding="utf-8"))
        for field, value in (
            ("status", "failed"),
            ("schema_version", True),
            ("unexpected", 1),
            ("files", []),
        ):
            with self.subTest(field=field):
                data = dict(original)
                data[field] = value
                self.receipt.write_text(json.dumps(data), encoding="utf-8")
                self.assertNotEqual(self.run_tool("verify").returncode, 0)
        self.receipt.write_text(
            '{"status":"failed","status":"passed"}', encoding="utf-8"
        )
        self.assertNotEqual(self.run_tool("verify").returncode, 0)

    def test_rejects_duplicate_and_nonportable_filenames(self) -> None:
        for name in (
            "app.zip",
            "APP.ZIP",
            "../escape",
            "dir/file",
            "dir\\file",
            "NUL.txt",
            "CON .txt",
            "CONIN$.zip",
            "CONOUT$.zip",
            "COM¹.zip",
            "COM².zip",
            "COM³.zip",
            "LPT¹.zip",
            "LPT².zip",
            "LPT³.zip",
            "end.",
        ):
            with self.subTest(name=name):
                self.assertNotEqual(
                    self.run_tool("create", "--file", name).returncode, 0
                )

    def test_windows_device_aliases_are_not_portable(self) -> None:
        for stem in (
            "CON",
            "NUL",
            "CONIN$",
            "CONOUT$",
            "COM¹",
            "COM²",
            "COM³",
            "LPT¹",
            "LPT²",
            "LPT³",
        ):
            with self.subTest(stem=stem):
                self.assertFalse(RECEIPT.valid_filename(stem + ".zip"))
                self.assertFalse(RECEIPT.valid_filename(stem.lower() + " .zip"))
        self.assertTrue(RECEIPT.valid_filename("COM10.zip"))
        self.assertTrue(RECEIPT.valid_filename("connector.zip"))

    def test_rejects_malformed_inputs_and_unsupported_tuples(self) -> None:
        for field, value in (
            ("revision", "abc"),
            ("run-id", "0"),
            ("run-attempt", "-1"),
            ("artifact-id", "x"),
            ("artifact-digest", "sha256:123"),
            ("repository", "../evil"),
            ("check", "../check"),
        ):
            with self.subTest(field=field):
                self.assertNotEqual(
                    self.run_tool("create", "--" + field, value).returncode, 0
                )
        for platform, arch, vendor in (
            ("linux", "arm64", "amd"),
            ("windows", "arm64", "amd"),
            ("windows", "arm64", "nvidia"),
        ):
            with self.subTest(platform=platform, arch=arch, vendor=vendor):
                self.assertNotEqual(
                    self.run_tool(
                        "create",
                        "--platform",
                        platform,
                        "--arch",
                        arch,
                        "--vendor",
                        vendor,
                    ).returncode,
                    0,
                )

    def test_rejects_linked_packages(self) -> None:
        target = self.root / "outside"
        target.write_bytes(b"gpu package")
        package = self.packages / "app.zip"
        package.unlink()
        try:
            package.symlink_to(target)
        except OSError as exc:
            self.skipTest(f"symlink creation unavailable: {exc}")
        self.assertNotEqual(self.run_tool("create").returncode, 0)


if __name__ == "__main__":
    unittest.main()
