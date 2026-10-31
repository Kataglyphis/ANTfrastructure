#!/usr/bin/env python3
"""Exercise the opt-in clean-host receipt protocol without apt, GitHub or a GPU."""

import hashlib
import json
import os
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ACTION = ROOT / ".github/actions/clean-host-package-check"
SCRIPT = ACTION / "clean-host-gpu-receipt.sh"


@unittest.skipIf(os.name == "nt", "the clean-host composite action runs on Linux")
class CleanHostReceiptTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.raw = self.root / "raw"
        self.raw.mkdir()
        self.archive = self.raw / "artifact.zip"
        self.files = {
            "engine.deb": b"deb",
            "engine.tar.gz": b"tar",
            "engine.AppImage": b"image",
        }
        with zipfile.ZipFile(
            self.archive, "w", compression=zipfile.ZIP_DEFLATED
        ) as archive:
            for name, contents in self.files.items():
                archive.writestr(name, contents)
        self.env = {
            **os.environ,
            "GPU_ARTIFACT_ID": "31",
            "GPU_ARTIFACT_DIGEST": hashlib.sha256(
                self.archive.read_bytes()
            ).hexdigest(),
            "GPU_ARTIFACT_FILES": "\n".join(self.files),
            "GPU_VENDOR": "nvidia",
            "GPU_ARCH": "x64",
            "GPU_RECEIPT": str(self.root / "receipt.json"),
            "GPU_MAX_BYTES": "4096",
            "GPU_MAX_RATIO": "100",
            "GPU_ARCHIVE_DIR": str(self.raw),
            "PACKAGE_SUBDIR": "",
            "DEB_GLOB": "*.deb",
            "DEB_COMMAND": "true",
            "TARBALL_GLOB": "*.tar.gz",
            "TARBALL_COMMAND": "true",
            "APPIMAGE_GLOB": "*.AppImage",
            "APPIMAGE_COMMAND": "true",
            "RUNNER_TEMP": str(self.root),
            "GITHUB_REPOSITORY": "Kataglyphis/Example",
            "GITHUB_SHA": "a" * 40,
            "GITHUB_RUN_ID": "41",
            "GITHUB_RUN_ATTEMPT": "2",
        }

    def run_mode(self, mode: str, **overrides: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(SCRIPT), mode],
            env={**self.env, **overrides},
            capture_output=True,
            text=True,
            check=False,
        )

    def test_cpu_default_needs_no_gpu_inputs(self) -> None:
        values = {key: "" for key in self.env if key.startswith("GPU_")}
        self.assertEqual(self.run_mode("validate", **values).returncode, 0)
        self.assertNotEqual(self.run_mode("prepare", **values).returncode, 0)
        self.assertNotEqual(
            self.run_mode("validate", **{**values, "GPU_VENDOR": "amd"}).returncode, 0
        )

    def test_pre_post_receipt_covers_the_same_extracted_files(self) -> None:
        result = self.run_mode("prepare")
        self.assertEqual(result.returncode, 0, result.stderr)
        packages = self.root / "clean-host-packages"
        self.assertEqual(
            {p.name: p.read_bytes() for p in packages.iterdir()}, self.files
        )
        self.assertFalse((self.root / "receipt.json").exists())
        self.assertNotEqual(
            self.run_mode("finish", GITHUB_RUN_ATTEMPT="3").returncode, 0
        )
        (packages / "engine.deb").write_bytes(b"modified")
        self.assertNotEqual(self.run_mode("finish").returncode, 0)
        self.assertFalse((self.root / "receipt.json").exists())
        (packages / "engine.deb").write_bytes(b"deb")
        result = self.run_mode("finish")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads((self.root / "receipt.json").read_text())
        self.assertEqual(data["identity"]["check"], "clean-host-inference")
        self.assertEqual(data["identity"]["run_attempt"], "2")
        self.assertNotEqual(self.run_mode("finish").returncode, 0)

    def test_partial_configuration_never_falls_back(self) -> None:
        cases = (
            {"GPU_ARTIFACT_ID": ""},
            {"GPU_ARTIFACT_ID": "31,32"},
            {"GPU_ARTIFACT_DIGEST": ""},
            {"GPU_ARTIFACT_DIGEST": "f" * 64},
            {"GPU_ARCH": "arm64", "GPU_VENDOR": "amd"},
            {"GPU_ARTIFACT_FILES": self.env["GPU_ARTIFACT_FILES"] + "\nextra.whl"},
            {"PACKAGE_SUBDIR": "nested"},
            {"APPIMAGE_COMMAND": ""},
        )
        for case in cases:
            with self.subTest(case=case):
                self.assertNotEqual(self.run_mode("prepare", **case).returncode, 0)
                self.assertFalse((self.root / "receipt.json").exists())

    def test_gpu_profile_receipt_requires_unchanged_packages_and_attempt(self) -> None:
        override = {
            "GPU_CHECK_NAME": "gpu-model-inference",
            "GPU_PACKAGES_DIR": str(self.root / "profile-packages"),
            "GPU_BEFORE_RECEIPT": str(self.root / "profile-before.json"),
        }
        result = self.run_mode("prepare", **override)
        self.assertEqual(result.returncode, 0, result.stderr)
        package = self.root / "profile-packages/engine.tar.gz"
        package.write_bytes(b"modified")
        self.assertNotEqual(self.run_mode("finish", **override).returncode, 0)
        package.write_bytes(b"tar")
        self.assertNotEqual(
            self.run_mode(
                "finish", **{**override, "GITHUB_RUN_ATTEMPT": "3"}
            ).returncode,
            0,
        )
        result = self.run_mode("finish", **override)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads((self.root / "receipt.json").read_text())
        self.assertEqual(data["identity"]["check"], "gpu-model-inference")

    def test_checked_receipts_stage_the_same_uploaded_archive(self) -> None:
        clean = self.root / "receipt.json"
        gpu = self.root / "profile-receipt.json"
        profile = {
            "GPU_CHECK_NAME": "gpu-model-inference",
            "GPU_PACKAGES_DIR": str(self.root / "profile-packages"),
            "GPU_BEFORE_RECEIPT": str(self.root / "profile-before.json"),
            "GPU_RECEIPT": str(gpu),
        }
        for mode, values in (
            ("prepare", {}),
            ("finish", {}),
            ("prepare", profile),
            ("finish", profile),
        ):
            result = self.run_mode(mode, **values)
            self.assertEqual(result.returncode, 0, result.stderr)
        identity = {
            "repository": self.env["GITHUB_REPOSITORY"],
            "revision": self.env["GITHUB_SHA"],
            "run-id": self.env["GITHUB_RUN_ID"],
            "run-attempt": self.env["GITHUB_RUN_ATTEMPT"],
            "artifact-id": self.env["GPU_ARTIFACT_ID"],
            "artifact-digest": self.env["GPU_ARTIFACT_DIGEST"],
            "platform": "linux",
            "arch": self.env["GPU_ARCH"],
            "vendor": self.env["GPU_VENDOR"],
        }
        output = self.root / "staged"
        command = [
            "python3",
            "-I",
            str(ROOT / "shared/python/stage_gpu_artifact.py"),
            "--archive",
            str(self.archive),
            "--clean-receipt",
            str(clean),
            "--gpu-receipt",
            str(gpu),
            "--output",
            str(output),
            "--max-uncompressed-bytes",
            "4096",
            "--max-compression-ratio",
            "100",
        ]
        for key, value in identity.items():
            command.extend(("--" + key, value))
        for name in self.files:
            command.extend(("--file", name))
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual({p.name: p.read_bytes() for p in output.iterdir()}, self.files)


def valid_action_wiring(text: str) -> bool:
    """Require ID download, precheck, actual clean-host check, then success-only receipt."""
    names = (
        "name: Download immutable GPU archive",
        "name: Prepare and snapshot GPU packages",
        "name: Install and start them",
        "name: Verify unchanged GPU packages and write clean-host receipt",
    )
    if not all(name in text for name in names):
        return False
    download, prepare, check, finish = (text.split(name, 1)[1] for name in names)
    return (
        [text.index(name) for name in names]
        == sorted(text.index(name) for name in names)
        and "artifact-ids: ${{ inputs.artifact-id }}" in download.split(names[1], 1)[0]
        and "skip-decompress: true" in download.split(names[1], 1)[0]
        and "digest-mismatch: error" in download.split(names[1], 1)[0]
        and 'clean-host-gpu-receipt.sh" prepare' in prepare.split(names[2], 1)[0]
        and 'clean-host-package-check.sh"' in check.split(names[3], 1)[0]
        and "PACKAGES_DIR: ${{ runner.temp }}/clean-host-packages/${{ inputs.subdir }}"
        in check.split(names[3], 1)[0]
        and "if: ${{ inputs.artifact-id != '' }}" in finish
        and 'clean-host-gpu-receipt.sh" finish' in finish
        and "always()" not in finish
        and text.count("GPU_CHECK_NAME: clean-host-inference") == 3
        and text.count("LD_PRELOAD: ''") == 3
        and text.count("LD_AUDIT: ''") == 3
        and text.count("GPU_PACKAGES_DIR: ${{ runner.temp }}/clean-host-packages") == 3
        and text.count(
            "GPU_BEFORE_RECEIPT: ${{ runner.temp }}/clean-host-gpu-before.json"
        )
        == 3
    )


class ActionWiringTest(unittest.TestCase):
    def test_receipt_is_gated_by_the_actual_clean_host_step(self) -> None:
        text = (ACTION / "action.yml").read_text(encoding="utf-8")
        self.assertTrue(valid_action_wiring(text))
        for original, replacement in (
            ("artifact-ids: ${{ inputs.artifact-id }}", "name: unsafe-name"),
            ("skip-decompress: true", "skip-decompress: false"),
            ("digest-mismatch: error", "digest-mismatch: warn"),
            ('clean-host-gpu-receipt.sh" prepare', 'clean-host-gpu-receipt.sh" skip'),
            ('clean-host-package-check.sh"', 'wrong-check.sh"'),
            (
                "PACKAGES_DIR: ${{ runner.temp }}/clean-host-packages/${{ inputs.subdir }}",
                "PACKAGES_DIR: /other",
            ),
            ('clean-host-gpu-receipt.sh" finish', 'clean-host-gpu-receipt.sh" skip'),
            ("if: ${{ inputs.artifact-id != '' }}", "if: ${{ always() }}"),
            (
                "GPU_CHECK_NAME: clean-host-inference",
                "GPU_CHECK_NAME: gpu-model-inference",
            ),
            ("LD_PRELOAD: ''", "LD_PRELOAD: /wrong"),
            (
                "GPU_PACKAGES_DIR: ${{ runner.temp }}/clean-host-packages",
                "GPU_PACKAGES_DIR: /other",
            ),
        ):
            with self.subTest(original=original):
                self.assertFalse(
                    valid_action_wiring(text.replace(original, replacement))
                )

    def test_profile_action_only_records_successful_checked_bytes(self) -> None:
        action = ROOT / ".github/actions/gpu-package-check/action.yml"
        text = action.read_text(encoding="utf-8")
        names = (
            "name: Validate GPU package check inputs",
            "name: Download immutable GPU archive",
            "name: Prepare and snapshot GPU packages",
            "name: Profile the exact extracted GPU packages",
            "name: Verify unchanged packages and write GPU receipt",
        )
        self.assertTrue(all(name in text for name in names))
        self.assertEqual(
            [text.index(name) for name in names],
            sorted(text.index(name) for name in names),
        )
        self.assertIn("artifact-ids: ${{ inputs.artifact-id }}", text)
        self.assertIn("skip-decompress: true", text)
        self.assertIn("digest-mismatch: error", text)
        self.assertIn('bash -c "$GPU_PROFILE_COMMAND"', text)
        self.assertEqual(text.count("GPU_CHECK_NAME: gpu-model-inference"), 3)
        self.assertEqual(text.count("LD_PRELOAD: ''"), 4)
        self.assertEqual(text.count("LD_AUDIT: ''"), 4)
        self.assertEqual(
            text.count(
                "GPU_PACKAGES_DIR: ${{ runner.temp }}/gpu-profile-packages-${{ inputs.artifact-id }}"
            ),
            2,
        )
        self.assertIn(
            'export GPU_PACKAGE_DIR="${RUNNER_TEMP}/gpu-profile-packages-${GPU_ARTIFACT_ID}"',
            text,
        )
        self.assertNotIn("always()", text)


if __name__ == "__main__":
    unittest.main()
