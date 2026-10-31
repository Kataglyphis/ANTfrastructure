#!/usr/bin/env python3
"""Exercise finished Linux GPU packages against a single wheel-proven bundle."""
import io
import json
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path

VERIFIER = Path(__file__).resolve().parents[1] / "06-packaging/verify-python-gpu-package.py"
CAPI = Path("runtime/lib/python3.15/site-packages/onnxruntime/capi")
LIBS = ("libonnxruntime.so.1.31.0", "libonnxruntime_providers_shared.so",
        "libonnxruntime_providers_cuda.so", "libonnxruntime_providers_tensorrt.so")


class FinishedPackageProof(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="gpu-package-proof-")
        self.root = Path(self.temp.name)
        self.bundle = self.root / "bundle"
        (self.bundle / CAPI).mkdir(parents=True)
        (self.bundle / "bundle.json").write_text(json.dumps({"required_provider": "CUDAExecutionProvider", "host_gpu_sonames": ["libcuda.so.1"]}))
        (self.bundle / "REQUIRES-GPU-RUNTIME.txt").write_text("install the GPU runtime\n")
        elf = b"\x7fELF\x02\x01" + bytes(12) + b"\x3e\x00" + bytes(64)
        for index, name in enumerate(LIBS):
            (self.bundle / CAPI / name).write_bytes(elf + bytes([index]))
        self.wheels = self.root / "wheels"
        self.wheels.mkdir()
        with zipfile.ZipFile(self.wheels / "onnxruntime_gpu-1.0-py3-none-any.whl", "w") as wheel:
            for name in LIBS:
                wheel.write(self.bundle / CAPI / name, f"onnxruntime/capi/{name}")
            wheel.writestr("onnxruntime/LICENSE", "test license")
            wheel.writestr("onnxruntime/ThirdPartyNotices.txt", "test notices")

    def tearDown(self):
        self.temp.cleanup()

    def package(self, kind, mutation):
        payload = self.root / "payload"
        shutil.rmtree(payload, ignore_errors=True)
        shutil.copytree(self.bundle, payload)
        provider = payload / CAPI
        if mutation.startswith("missing-"):
            (provider / f"libonnxruntime_providers_{mutation[8:]}.so").unlink()
        elif mutation.startswith("altered-"):
            (provider / f"libonnxruntime_providers_{mutation[8:]}.so").write_bytes(b"altered")
        elif mutation == "extra":
            (provider / "libonnxruntime_providers_rogue.so").write_bytes(b"rogue")
        elif mutation == "metadata":
            (payload / "REQUIRES-GPU-RUNTIME.txt").write_text("changed")
        elif mutation == "linked":
            file = provider / "libonnxruntime_providers_cuda.so"
            file.unlink()
            file.symlink_to("libonnxruntime_providers_shared.so")
        prefix = {"tar": "example", "deb": "opt/example", "appimage": "usr/lib/example"}[kind]
        tree = self.root / "tree"
        shutil.rmtree(tree, ignore_errors=True)
        (tree / prefix).parent.mkdir(parents=True)
        shutil.copytree(payload, tree / prefix, symlinks=True)
        if kind == "tar":
            artifact = self.root / "package.tar.gz"
            with tarfile.open(artifact, "w:gz") as archive:
                archive.add(tree / prefix, arcname=prefix)
                if mutation == "duplicate":
                    name = f"{prefix}/{CAPI}/libonnxruntime_providers_cuda.so"
                    data = (provider / "libonnxruntime_providers_cuda.so").read_bytes()
                    entry = tarfile.TarInfo(name)
                    entry.size = len(data)
                    archive.addfile(entry, io.BytesIO(data))
        elif kind == "deb":
            (tree / "DEBIAN").mkdir()
            (tree / "DEBIAN/control").write_text("Package: example\nVersion: 1\nArchitecture: all\nMaintainer: Test <test@example.invalid>\nDescription: test\n")
            artifact = self.root / "package.deb"
            subprocess.run(["dpkg-deb", "--build", str(tree), str(artifact)], check=True, stdout=subprocess.DEVNULL)
        else:
            archive_path = self.root / "appimage-payload.tar"
            with tarfile.open(archive_path, "w") as archive:
                archive.add(tree / "usr", arcname="usr")
            artifact = self.root / "package.AppImage"
            artifact.write_text(f'#!/bin/sh\n[ "$1" = --appimage-extract ] || exit 1\nmkdir squashfs-root\ntar -xf "{archive_path}" -C squashfs-root\n')
            artifact.chmod(0o755)
        return artifact, prefix

    def verify(self, kind, mutation):
        artifact, prefix = self.package(kind, mutation)
        return subprocess.run(["python3", str(VERIFIER), "--bundle", str(self.bundle), "--wheel-dir", str(self.wheels),
                               "--artifact", str(artifact), "--prefix", prefix], capture_output=True, text=True)

    def test_valid_and_mutated_finished_formats(self):
        for kind in ("tar", "deb", "appimage"):
            for mutation in ("valid", "missing-cuda", "missing-tensorrt", "altered-cuda", "altered-tensorrt", "extra", "metadata", "linked"):
                with self.subTest(kind=kind, mutation=mutation):
                    result = self.verify(kind, mutation)
                    self.assertEqual(result.returncode == 0, mutation == "valid", result.stdout + result.stderr)

    def test_duplicate_archive_provider_rejected(self):
        self.assertNotEqual(self.verify("tar", "duplicate").returncode, 0)

    def test_source_provider_not_in_wheel_rejected(self):
        (self.bundle / CAPI / "libonnxruntime_providers_rogue.so").write_bytes((self.bundle / CAPI / LIBS[0]).read_bytes())
        self.assertNotEqual(self.verify("tar", "valid").returncode, 0)

    def test_source_provider_modified_after_wheel_build_rejected(self):
        (self.bundle / CAPI / LIBS[-1]).write_bytes((self.bundle / CAPI / LIBS[0]).read_bytes())
        self.assertNotEqual(self.verify("tar", "valid").returncode, 0)


if __name__ == "__main__":
    unittest.main()
