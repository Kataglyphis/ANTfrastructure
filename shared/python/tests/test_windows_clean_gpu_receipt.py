#!/usr/bin/env python3
"""Test receipt boundaries with fake packages; no installation or GPU is used."""

import argparse
import hashlib
import importlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
driver = importlib.import_module("windows_clean_gpu_receipt")


class CleanReceiptTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / "artifact.zip"
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("app.msi", b"fake msi")
            archive.writestr("app.msix", b"fake msix")
            archive.writestr("app-testcert.cer", b"fake cert")
        self.script = self.root / "check.ps1"
        self.script.write_text("exit 0", encoding="utf-8")
        self.output = self.root / "receipt.json"
        self.work = self.root / "work"
        self.work.mkdir()
        self.args = argparse.Namespace(
            archive=str(self.archive),
            receipt=str(self.output),
            producer_receipt=str(self.root / "producer.json"),
            script=str(self.script),
            work=str(self.work),
            pwsh="pwsh",
            file=["app.msi", "app.msix", "app-testcert.cer"],
            max_uncompressed_bytes=4096,
            max_compression_ratio=100,
            floor=0,
            cushion=0,
            timeout=1,
            repository="Kataglyphis/OmniAccelerANT",
            revision="a" * 40,
            run_id="41",
            run_attempt="2",
            artifact_id="31",
            artifact_digest=hashlib.sha256(self.archive.read_bytes()).hexdigest(),
            platform="windows",
            arch="x64",
            vendor="amd",
        )
        packages = self.root / "producer-packages"
        packages.mkdir()
        with zipfile.ZipFile(self.archive) as archive:
            archive.extractall(packages)
        identity = {
            key: getattr(self.args, key)
            for key in driver.receipt.IDENTITY
            if key != "check"
        }
        driver.receipt.execute(
            argparse.Namespace(
                **identity,
                check="producer-verified",
                file=self.args.file,
                receipt=self.args.producer_receipt,
                directory=str(packages),
                operation="create",
            )
        )

    def no_scratch(self) -> None:
        self.assertEqual(list(self.work.glob("windows-gpu-clean-*")), [])

    def test_success_receipt_binds_the_unmodified_packages(self) -> None:
        def run(command, *, timeout, env):
            self.assertEqual(command[-1], str(self.script))
            self.assertEqual(timeout, 1)
            self.assertEqual(env["GPU_VENDOR"], "amd")
            self.assertEqual(
                (Path(env["GPU_PACKAGE_DIR"]) / "app.msi").read_bytes(), b"fake msi"
            )

        with mock.patch.object(driver.process, "run_process", side_effect=run):
            driver.check(self.args)
        data = json.loads(self.output.read_text(encoding="utf-8"))
        self.assertEqual(data["identity"]["check"], "clean-host-inference")
        self.assertEqual(data["identity"]["run_attempt"], "2")
        self.assertEqual(
            data["files"]["app.msi"], hashlib.sha256(b"fake msi").hexdigest()
        )
        self.no_scratch()

    @unittest.skipUnless(
        os.name == "nt" and shutil.which("pwsh"), "requires Windows PowerShell"
    )
    def test_real_powershell_checks_the_synthetic_package(self) -> None:
        self.script.write_text(
            "$ErrorActionPreference = 'Stop'\n"
            "if ($env:GPU_VENDOR -ne 'amd') { exit 2 }\n"
            "if ((Get-Content -Raw -LiteralPath "
            "(Join-Path $env:GPU_PACKAGE_DIR 'app.msi')) -ne 'fake msi') { exit 3 }\n",
            encoding="utf-8",
        )
        self.args.pwsh = shutil.which("pwsh")
        self.args.timeout = 30
        driver.check(self.args)
        self.assertTrue(self.output.is_file())
        self.no_scratch()

    @unittest.skipUnless(
        os.name == "nt" and shutil.which("pwsh"), "requires Windows PowerShell"
    )
    def test_action_publishes_only_after_scratch_cleanup(self) -> None:
        action = ROOT.parents[1] / ".github/actions/windows-clean-gpu-check/action.yml"
        source = action.read_text(encoding="utf-8")
        block = source.split("    - name: Remove scratch before publishing", 1)[1]
        block = block.split("      run: |\n", 1)[1].split("\n    - name:", 1)[0]
        script = "\n".join(line[8:] for line in block.splitlines())
        for mode in ("cleanup-fails", "existing-receipt", "success"):
            with self.subTest(mode=mode):
                root = self.root / "windows-gpu-clean-0123456789abcdef0123456789abcdef"
                root.mkdir()
                (root / "pending.json").write_text("receipt", encoding="ascii")
                if mode == "existing-receipt":
                    self.output.write_text("original", encoding="ascii")
                override = (
                    "function Remove-Item { throw 'injected cleanup failure' }\n"
                    if mode == "cleanup-fails"
                    else ""
                )
                check_script = self.root / "finalize.ps1"
                check_script.write_text(override + script, encoding="utf-8")
                env = os.environ.copy()
                env.update(
                    RUNNER_TEMP=str(self.root),
                    GPU_ROOT=str(root),
                    GPU_RECEIPT=str(self.output),
                )
                result = subprocess.run(
                    [shutil.which("pwsh"), "-NoProfile", "-File", str(check_script)],
                    env=env,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(
                    result.returncode == 0, mode == "success", result.stderr
                )
                if mode == "cleanup-fails":
                    self.assertFalse(self.output.exists())
                    shutil.rmtree(root)
                else:
                    self.assertFalse(root.exists())
                    expected = "original" if mode == "existing-receipt" else "receipt"
                    self.assertEqual(self.output.read_text(encoding="ascii"), expected)
                    self.output.unlink()

    def test_failed_or_mutating_script_never_produces_receipt(self) -> None:
        def mutate(command, *, timeout, env):
            (Path(env["GPU_PACKAGE_DIR"]) / "app.msi").write_bytes(b"modified")

        for effect in (RuntimeError("script failed"), mutate):
            with (
                self.subTest(effect=effect),
                mock.patch.object(driver.process, "run_process", side_effect=effect),
            ):
                with self.assertRaises((RuntimeError, ValueError)):
                    driver.check(self.args)
                self.assertFalse(self.output.exists())
                self.no_scratch()

    def test_cleanup_failure_does_not_publish_receipt(self) -> None:
        real_directory = tempfile.TemporaryDirectory

        class FailingCleanup:
            def __init__(self, *args, **kwargs):
                self.directory = real_directory(*args, **kwargs)

            def __enter__(self):
                return self.directory.__enter__()

            def __exit__(self, *args):
                self.directory.__exit__(*args)
                raise OSError("injected cleanup failure")

        def temporary_directory(*args, **kwargs):
            if kwargs.get("prefix") == "windows-gpu-clean-":
                return FailingCleanup(*args, **kwargs)
            return real_directory(*args, **kwargs)

        for check_name in ("clean-host-inference", "gpu-model-inference"):
            with self.subTest(check_name=check_name):
                if check_name == "gpu-model-inference":
                    self.profile_args()

                def run_callback(command, *, timeout, env):
                    if "GPU_EVIDENCE_DIR" in env:
                        (Path(env["GPU_EVIDENCE_DIR"]) / "profile.json").write_text(
                            "{}", encoding="utf-8"
                        )

                with (
                    mock.patch.object(
                        driver.tempfile, "TemporaryDirectory", temporary_directory
                    ),
                    mock.patch.object(
                        driver.process, "run_process", side_effect=run_callback
                    ) as run,
                    self.assertRaisesRegex(OSError, "injected cleanup failure"),
                ):
                    driver.check(self.args)
                run.assert_called_once()
                self.assertFalse(self.output.exists())
                self.no_scratch()

    def test_invalid_input_cannot_run_check_or_produce_receipt(self) -> None:
        for field, value in (
            ("artifact_digest", "f" * 64),
            ("arch", "arm64"),
            ("file", ["../app.msi"]),
            ("max_uncompressed_bytes", 1),
            ("floor", 10**30),
            ("producer_receipt", str(self.output)),
        ):
            with self.subTest(field=field):
                old = getattr(self.args, field)
                setattr(self.args, field, value)
                with mock.patch.object(driver.process, "run_process") as run:
                    with self.assertRaises((ValueError, OSError)):
                        driver.check(self.args)
                    run.assert_not_called()
                self.assertFalse(self.output.exists())
                self.no_scratch()
                setattr(self.args, field, old)

    def test_producer_receipt_must_match_downloaded_package_bytes(self) -> None:
        producer = Path(self.args.producer_receipt)
        data = json.loads(producer.read_text(encoding="utf-8"))
        data["files"]["app.msi"] = "f" * 64
        producer.write_text(json.dumps(data), encoding="utf-8")
        with mock.patch.object(driver.process, "run_process") as run:
            with self.assertRaises(ValueError):
                driver.check(self.args)
            run.assert_not_called()
        self.assertFalse(self.output.exists())
        self.no_scratch()

    def test_existing_receipt_is_not_replaced(self) -> None:
        self.output.write_text("original", encoding="ascii")
        with self.assertRaises(ValueError):
            driver.check(self.args)
        self.assertEqual(self.output.read_text(encoding="ascii"), "original")
        self.no_scratch()

    def profile_args(self) -> Path:
        evidence = self.root / "evidence"
        evidence.mkdir()
        self.args.check = "gpu-model-inference"
        self.args.evidence_dir = str(evidence)
        return evidence

    def test_gpu_profile_receipt_binds_producer_bytes_and_evidence(self) -> None:
        evidence = self.profile_args()

        def run(command, *, timeout, env):
            self.assertEqual(env["GPU_EVIDENCE_DIR"], str(evidence))
            self.assertEqual(env["GPU_DEVICE_INDEX"], "2")
            self.assertTrue((Path(env["GPU_PACKAGE_DIR"]) / "app.msi").is_file())
            (evidence / "profile.json").write_text("{}", encoding="utf-8")

        with (
            mock.patch.dict(os.environ, {"GPU_DEVICE_INDEX": "2"}),
            mock.patch.object(driver.process, "run_process", side_effect=run),
        ):
            driver.check(self.args)
        data = json.loads(self.output.read_text(encoding="utf-8"))
        self.assertEqual(data["identity"]["check"], "gpu-model-inference")
        self.assertTrue((evidence / "profile.json").is_file())
        self.no_scratch()

    @unittest.skipUnless(
        os.name == "nt" and shutil.which("pwsh"), "requires Windows PowerShell"
    )
    def test_gpu_profile_executes_a_real_synthetic_callback(self) -> None:
        evidence = self.profile_args()
        self.args.pwsh = shutil.which("pwsh")
        self.args.timeout = 30
        self.script.write_text(
            "$ErrorActionPreference = 'Stop'\n"
            "if ($env:GPU_VENDOR -ne 'amd') { exit 2 }\n"
            "if (-not (Test-Path -LiteralPath (Join-Path $env:GPU_PACKAGE_DIR 'app.msi'))) { exit 3 }\n"
            "Set-Content -LiteralPath (Join-Path $env:GPU_EVIDENCE_DIR 'profile.json') -Value '{}'\n",
            encoding="utf-8",
        )
        driver.check(self.args)
        self.assertTrue((evidence / "profile.json").is_file())
        self.assertEqual(
            json.loads(self.output.read_text(encoding="utf-8"))["identity"]["check"],
            "gpu-model-inference",
        )
        self.no_scratch()

    def test_gpu_profile_rejects_failure_mutation_and_missing_evidence(self) -> None:
        evidence = self.profile_args()

        def mutate(command, *, timeout, env):
            (evidence / "profile.json").write_text("{}", encoding="utf-8")
            (Path(env["GPU_PACKAGE_DIR"]) / "app.msi").write_bytes(b"changed")

        for effect in (RuntimeError("callback failed"), mutate, None):
            with self.subTest(effect=effect):
                with (
                    mock.patch.object(
                        driver.process, "run_process", side_effect=effect
                    ),
                    self.assertRaises((RuntimeError, ValueError)),
                ):
                    driver.check(self.args)
                self.assertFalse(self.output.exists())
                self.no_scratch()
                for path in evidence.iterdir():
                    path.unlink()

    def test_gpu_profile_requires_empty_safe_evidence(self) -> None:
        evidence = self.profile_args()
        stale = evidence / "stale.json"
        stale.write_text("{}", encoding="utf-8")
        with mock.patch.object(driver.process, "run_process") as run:
            with self.assertRaises(ValueError):
                driver.check(self.args)
            run.assert_not_called()
        stale.unlink()

        def unsafe(command, *, timeout, env):
            path = evidence / "profile.json"
            path.write_text("{}", encoding="utf-8")

        real_link = driver.receipt.is_link
        with (
            mock.patch.object(driver.process, "run_process", side_effect=unsafe),
            mock.patch.object(
                driver.receipt,
                "is_link",
                side_effect=lambda path: path.name == "profile.json" or real_link(path),
            ),
            self.assertRaises(ValueError),
        ):
            driver.check(self.args)
        self.assertFalse(self.output.exists())
        self.no_scratch()

    def test_gpu_receipt_can_be_in_evidence_but_floor_is_enforced(self) -> None:
        evidence = self.profile_args()
        self.output = evidence / "receipt.json"
        self.args.receipt = str(self.output)

        def run(command, *, timeout, env):
            (evidence / "profile.json").write_text("{}", encoding="utf-8")

        self.args.floor = 1
        with (
            mock.patch.object(driver.process, "run_process", side_effect=run),
            mock.patch.object(
                driver.shutil,
                "disk_usage",
                side_effect=[mock.Mock(free=1024), mock.Mock(free=0)],
            ),
            self.assertRaisesRegex(ValueError, "disk floor"),
        ):
            driver.check(self.args)
        self.assertFalse(self.output.exists())
        self.no_scratch()
        (evidence / "profile.json").unlink()
        with mock.patch.object(driver.process, "run_process", side_effect=run):
            driver.check(self.args)
        self.assertTrue(self.output.is_file())
        self.no_scratch()

    def test_extraction_checks_measured_bytes_plus_hosted_reserve(self) -> None:
        with zipfile.ZipFile(self.archive) as archive:
            expanded = sum(item.file_size for item in archive.infolist())
        self.args.floor = 2 * 1024**3
        self.args.cushion = 2 * 1024**3
        required = expanded + self.args.floor + self.args.cushion
        for free, expected in ((required - 1, False), (required, True)):
            with (
                self.subTest(free=free),
                mock.patch.object(
                    driver.shutil, "disk_usage", return_value=mock.Mock(free=free)
                ),
                mock.patch.object(driver.process, "run_process") as run,
            ):
                if expected:
                    driver.check(self.args)
                    run.assert_called_once()
                    self.assertTrue(self.output.is_file())
                    self.output.unlink()
                else:
                    with self.assertRaisesRegex(ValueError, "insufficient disk space"):
                        driver.check(self.args)
                    run.assert_not_called()
                    self.assertFalse(self.output.exists())
                self.no_scratch()

    @unittest.skipUnless(
        os.name == "nt" and shutil.which("pwsh"), "requires Windows PowerShell"
    )
    def test_action_checks_archive_size_before_download(self) -> None:
        available = shutil.disk_usage(self.root).free
        reserve = 4 * 1024**3
        margin = 64 * 1024**2
        if available < reserve + 2 * margin:
            self.skipTest("not enough free space to exercise the synthetic threshold")
        action = ROOT.parents[1] / ".github/actions/windows-clean-gpu-check/action.yml"
        source = action.read_text(encoding="utf-8")
        self.assertIn("--floor 2147483648 --cushion 2147483648", source)
        block = source.split("    - name: Allocate clean-host scratch\n", 1)[1]
        block = block.split("      run: |\n", 1)[1].split("\n    - name:", 1)[0]
        script = self.root / "allocate.ps1"
        script.write_text(
            "\n".join(line[8:] for line in block.splitlines()), encoding="utf-8"
        )
        for adjustment, expected in ((-margin, True), (margin, False)):
            output = self.root / "outputs.txt"
            output.unlink(missing_ok=True)
            env = os.environ.copy()
            env.update(
                RUNNER_TEMP=str(self.root),
                RUNNER_OS="Windows",
                RUNNER_ARCH="X64",
                RUNNER_ENVIRONMENT="github-hosted",
                GPU_ARCHIVE_SIZE=str(available - reserve + adjustment),
                GITHUB_OUTPUT=str(output),
            )
            result = subprocess.run(
                [shutil.which("pwsh"), "-NoProfile", "-File", str(script)],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode == 0, expected, result.stderr)
            if expected:
                root = Path(output.read_text(encoding="utf-8").strip().split("=", 1)[1])
                self.assertEqual(root.parent, self.root)
                shutil.rmtree(root)
            else:
                self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
