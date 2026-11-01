#!/usr/bin/env python3
"""Exercise staged bytes; no GPU check, GitHub service, or receipt authenticity is proved."""

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
import warnings
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STAGE = ROOT / "stage_gpu_artifact.py"
RECEIPT = ROOT / "gpu_artifact_receipt.py"


class StageTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.files = self.root / "packages"
        self.files.mkdir()
        self.data = {"engine.deb": b"deb payload", "engine.AppImage": b"image payload"}
        for name, data in self.data.items():
            (self.files / name).write_bytes(data)
        self.archive = self.root / "artifact.zip"
        self.output = self.root / "output"
        self.clean = self.root / "clean.json"
        self.gpu = self.root / "gpu.json"
        self.identity = {
            "repository": "Kataglyphis/AccelerANTgine",
            "revision": "a" * 40,
            "run-id": "41",
            "run-attempt": "2",
            "artifact-id": "31",
            "platform": "linux",
            "arch": "x64",
            "vendor": "nvidia",
        }
        self.make_archive()
        self.make_receipts()

    def make_archive(
        self, extra: list[tuple[zipfile.ZipInfo | str, bytes]] | None = None
    ) -> None:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(
                self.archive, "w", compression=zipfile.ZIP_DEFLATED
            ) as out:
                for name, data in self.data.items():
                    out.writestr(name, data)
                for name, data in extra or []:
                    out.writestr(name, data)
        self.identity["artifact-digest"] = hashlib.sha256(
            self.archive.read_bytes()
        ).hexdigest()

    def test_windows_installer_archive_uses_both_exact_receipts(self) -> None:
        """Synthetic files exercise receipt binding, not Windows installation or GPU use."""
        for path in self.files.iterdir():
            path.unlink()
        self.data = {
            "app.msi": b"msi payload",
            "app.msix": b"msix payload",
            "app-testcert.cer": b"certificate payload",
        }
        for name, data in self.data.items():
            (self.files / name).write_bytes(data)
        self.identity.update(platform="windows", arch="x64", vendor="amd")
        self.make_archive()
        self.make_receipts()
        gpu_data = json.loads(self.gpu.read_text(encoding="utf-8"))
        gpu_data["files"]["app.msi"] = "f" * 64
        self.gpu.write_text(json.dumps(gpu_data), encoding="utf-8")
        self.assertNotEqual(self.run_stage().returncode, 0)
        self.assertFalse(self.output.exists())
        self.make_receipts()
        result = self.run_stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            {p.name: p.read_bytes() for p in self.output.iterdir()}, self.data
        )

    def make_receipts(self) -> None:
        for path, check in (
            (self.clean, "clean-host-inference"),
            (self.gpu, "gpu-model-inference"),
        ):
            path.unlink(missing_ok=True)
            args = [
                sys.executable,
                str(RECEIPT),
                "create",
                "--directory",
                str(self.files),
                "--receipt",
                str(path),
                "--check",
                check,
            ]
            for key, value in self.identity.items():
                args += ["--" + key, value]
            for name in self.data:
                args += ["--file", name]
            subprocess.run(args, check=True, capture_output=True, text=True)

    def run_stage(self, *extra: str) -> subprocess.CompletedProcess[str]:
        args = [
            sys.executable,
            str(STAGE),
            "--archive",
            str(self.archive),
            "--output",
            str(self.output),
            "--clean-receipt",
            str(self.clean),
            "--gpu-receipt",
            str(self.gpu),
            "--max-uncompressed-bytes",
            "4096",
            "--max-compression-ratio",
            "100",
        ]
        for key, value in self.identity.items():
            args += ["--" + key, value]
        for name in self.data:
            args += ["--file", name]
        return subprocess.run(
            args + list(extra), check=False, capture_output=True, text=True
        )

    def rejected(self, *extra: str) -> None:
        self.assertNotEqual(self.run_stage(*extra).returncode, 0)
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.root.glob(".gpu-stage-*")), [])

    def test_matching_receipts_and_archive_stage_exact_bytes(self) -> None:
        result = self.run_stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            {p.name: p.read_bytes() for p in self.output.iterdir()}, self.data
        )

    def test_pinned_upload_artifact_writer_fixture(self) -> None:
        fixture = ROOT / "tests/fixtures/upload-artifact-v7.0.2-flat.zip"
        content = fixture.read_bytes()
        digest = hashlib.sha256(content).hexdigest()
        self.assertEqual(
            digest, "21c25e4fab1ebe73d93e0709ab4ba293706fc3ab850c6762aac236ef9e9a8b93"
        )
        self.data = {
            "oxidant_3.0.0+gpu-amd_amd64.deb": b"package-0\n",
            "oxidant-3.0.0+gpu-amd-linux_x64.tar.gz": b"package-1\n" * 2,
            "oxidant-3.0.0+gpu-amd-x86_64.AppImage": b"package-2\n" * 3,
        }
        for path in self.files.iterdir():
            path.unlink()
        for name, data in self.data.items():
            (self.files / name).write_bytes(data)
        self.archive.write_bytes(content)
        self.identity["artifact-digest"] = digest
        prepared = self.root / "prepared"
        args = [
            sys.executable,
            "-I",
            str(ROOT / "prepare_gpu_artifact.py"),
            "--archive",
            str(self.archive),
            "--output",
            str(prepared),
            "--before-receipt",
            str(self.root / "before.json"),
            "--max-uncompressed-bytes",
            "4096",
            "--max-compression-ratio",
            "100",
        ]
        for key, value in self.identity.items():
            args += ["--" + key, value]
        for name in self.data:
            args += ["--file", name]
        result = subprocess.run(args, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            {p.name: p.read_bytes() for p in prepared.iterdir()}, self.data
        )
        self.make_receipts()
        result = self.run_stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            {p.name: p.read_bytes() for p in self.output.iterdir()}, self.data
        )

    @unittest.skipIf(os.name == "nt", "the composite action fixture uses Linux Bash")
    def test_composite_action_stages_the_checked_archive(self) -> None:
        repo = ROOT.parents[1]
        action = repo / ".github/actions/stage-gpu-artifact"
        content = (action / "action.yml").read_text(encoding="utf-8")
        script = textwrap.dedent(content.split("      run: |\n", 1)[1])
        env = {
            **os.environ,
            "GITHUB_ACTION_PATH": str(action),
            "GPU_ARCHIVE": str(self.archive),
            "GPU_CLEAN_RECEIPT": str(self.clean),
            "GPU_PROFILE_RECEIPT": str(self.gpu),
            "GPU_OUTPUT": str(self.output),
            "GPU_ARTIFACT_ID": self.identity["artifact-id"],
            "GPU_ARTIFACT_DIGEST": self.identity["artifact-digest"],
            "GPU_ARTIFACT_FILES": "\n".join(self.data),
            "GPU_VENDOR": self.identity["vendor"],
            "GPU_PLATFORM": self.identity["platform"],
            "GPU_ARCH": self.identity["arch"],
            "GPU_MAX_BYTES": "4096",
            "GPU_MAX_RATIO": "100",
            "GITHUB_REPOSITORY": self.identity["repository"],
            "GITHUB_SHA": self.identity["revision"],
            "GITHUB_RUN_ID": self.identity["run-id"],
            "GITHUB_RUN_ATTEMPT": self.identity["run-attempt"],
        }
        result = subprocess.run(
            ["bash", "-c", script], env=env, capture_output=True, text=True, check=False
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            {p.name: p.read_bytes() for p in self.output.iterdir()}, self.data
        )

    def test_existing_output_is_never_replaced(self) -> None:
        self.output.mkdir()
        (self.output / "keep").write_bytes(b"untouched")
        self.assertNotEqual(self.run_stage().returncode, 0)
        self.assertEqual((self.output / "keep").read_bytes(), b"untouched")

    def test_wrong_artifact_digest_and_wrong_attempt_fail(self) -> None:
        self.rejected("--artifact-digest", "b" * 64)
        self.rejected("--run-attempt", "3")
        self.archive.write_bytes(self.archive.read_bytes() + b"tampered")
        self.rejected()

    def test_self_consistent_receipts_cannot_lie_about_archive_digest(self) -> None:
        self.identity["artifact-digest"] = "b" * 64
        self.make_receipts()
        self.rejected()

    def test_both_receipts_must_match_the_actual_package_bytes(self) -> None:
        for path in (self.clean, self.gpu):
            data = json.loads(path.read_text())
            data["files"]["engine.deb"] = "f" * 64
            path.write_text(json.dumps(data))
        self.rejected()

    def test_atomic_publish_does_not_replace_even_an_empty_directory(self) -> None:
        source = self.root / "source"
        target = self.root / "target"
        source.mkdir()
        target.mkdir()
        code = (
            "import sys; from pathlib import Path; sys.path.insert(0, sys.argv[1]); "
            "from stage_gpu_artifact import publish_noreplace; "
            "publish_noreplace(Path(sys.argv[2]), Path(sys.argv[3]))"
        )
        result = subprocess.run(
            [sys.executable, "-c", code, str(ROOT), str(source), str(target)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(source.is_dir())
        self.assertTrue(target.is_dir())

    @unittest.skipIf(os.name == "nt", "renameat2 applies only on Linux")
    def test_unsupported_filesystem_fails_closed_with_clear_error(self) -> None:
        source = self.root / "source"
        target = self.root / "target"
        source.mkdir()
        code = textwrap.dedent("""
            import ctypes, errno, sys
            from pathlib import Path
            from unittest.mock import patch
            sys.path.insert(0, sys.argv[1])
            import stage_gpu_artifact as stage

            class Rename:
                def __call__(self, *args):
                    ctypes.set_errno(errno.EINVAL)
                    return -1

            class Libc:
                renameat2 = Rename()

            with patch.object(stage.ctypes, "CDLL", return_value=Libc()):
                stage.publish_noreplace(Path(sys.argv[2]), Path(sys.argv[3]))
        """)
        result = subprocess.run(
            [sys.executable, "-c", code, str(ROOT), str(source), str(target)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("filesystem or system rejected atomic no-replace", result.stderr)
        self.assertTrue(source.is_dir())
        self.assertFalse(target.exists())

    def test_missing_wrong_or_tampered_receipts_fail(self) -> None:
        self.rejected("--gpu-receipt", str(self.clean))
        for key, value in (
            ("check", "other"),
            ("artifact_id", "32"),
            ("run_attempt", "1"),
        ):
            original = json.loads(self.gpu.read_text())
            modified = json.loads(self.gpu.read_text())
            modified["identity"][key] = value
            self.gpu.write_text(json.dumps(modified))
            self.rejected()
            self.gpu.write_text(json.dumps(original))
        modified = json.loads(self.gpu.read_text())
        modified["files"]["engine.deb"] = "f" * 64
        self.gpu.write_text(json.dumps(modified))
        self.rejected()
        self.gpu.unlink()
        self.rejected()

    def test_archive_rejects_extra_traversal_duplicate_and_symlink(self) -> None:
        symlink = zipfile.ZipInfo("link")
        symlink.create_system = 3
        symlink.external_attr = 0o120777 << 16
        for extra in (
            ("../escape", b"x"),
            ("engine.deb", b"duplicate"),
            (symlink, b"target"),
        ):
            with self.subTest(extra=str(extra[0])):
                self.make_archive([extra])
                self.make_receipts()
                self.rejected()

    def test_archive_rejects_expected_symlink(self) -> None:
        symlink = zipfile.ZipInfo("engine.deb")
        symlink.create_system = 3
        symlink.external_attr = 0o120777 << 16
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr(symlink, self.data["engine.deb"])
            archive.writestr("engine.AppImage", self.data["engine.AppImage"])
        self.identity["artifact-digest"] = hashlib.sha256(
            self.archive.read_bytes()
        ).hexdigest()
        self.make_receipts()
        self.rejected()

    def test_expansion_limits_and_unsupported_tuples_fail(self) -> None:
        self.rejected("--max-uncompressed-bytes", "2")
        self.rejected("--max-compression-ratio", "0")
        self.rejected("--platform", "windows", "--arch", "arm64")
        self.rejected("--arch", "arm64", "--vendor", "amd")
        self.data["engine.deb"] = b"x" * 2000
        (self.files / "engine.deb").write_bytes(self.data["engine.deb"])
        self.make_archive()
        self.make_receipts()
        self.rejected("--max-compression-ratio", "2")


if __name__ == "__main__":
    unittest.main()
