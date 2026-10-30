"""Exercise NVIDIA OpenCV runtime provenance with isolated synthetic files."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = (
    Path(__file__).resolve().parents[1] / "diagnostics/Test-NvidiaOpenCvRuntime.ps1"
)


class NvidiaOpenCvRuntimeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="nvidia-opencv-proof-")
        self.root = Path(self.temp.name)
        self.bundle = self.root / "bundle"
        self.bin = self.bundle / "runtime/Lib/site-packages/cv2/bin"
        self.bin.mkdir(parents=True)
        self.licenses = self.bundle / "licenses"
        self.licenses.mkdir()
        self.cuda = self.root / "cuda/v13.4"
        self.cudnn = self.root / "cudnn/v9.27.0.42"
        self.runtime = self.root / "runtime"
        for root in (self.cuda, self.cudnn):
            (root / "bin/x64").mkdir(parents=True)
            (root / "LICENSE").write_bytes(b"original license")
        (self.runtime / "bin").mkdir(parents=True)
        for name, root in (
            ("cublas64_13.dll", self.cuda),
            ("cudnn64_9.dll", self.cudnn),
        ):
            (root / "bin/x64" / name).write_bytes(b"original runtime")
            shutil.copy2(root / "bin/x64" / name, self.runtime / "bin" / name)
            shutil.copy2(root / "bin/x64" / name, self.bin / name)
        shutil.copy2(
            self.cuda / "LICENSE", self.licenses / "nvidia-cuda-13.4-LICENSE.txt"
        )
        shutil.copy2(
            self.cudnn / "LICENSE", self.licenses / "nvidia-cudnn-9.27.0.42-LICENSE.txt"
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_check(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "pwsh",
                "-NoProfile",
                "-File",
                str(SCRIPT),
                "-Bundle",
                str(self.bundle),
                "-CudaVersion",
                "13.4",
                "-CudnnVersion",
                "9.27.0.42",
                "-RuntimeRoot",
                str(self.runtime),
            ],
            env=os.environ
            | {"CUDA_PATH": str(self.cuda), "CUDNN_ROOT": str(self.cudnn)},
            text=True,
            capture_output=True,
            check=False,
        )

    def test_matching_runtime_and_licenses(self) -> None:
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_cpu_only_bundle_does_not_require_sdk_roots(self) -> None:
        for path in self.bin.iterdir():
            path.unlink()
        shutil.rmtree(self.cuda)
        shutil.rmtree(self.cudnn)
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_or_mismatched_license_is_rejected(self) -> None:
        license_path = self.licenses / "nvidia-cuda-13.4-LICENSE.txt"
        license_path.unlink()
        self.assertNotEqual(self.run_check().returncode, 0)
        license_path.write_bytes(b"wrong license")
        self.assertNotEqual(self.run_check().returncode, 0)
        license_path.write_bytes(b"original license")
        (self.cudnn / "LICENSE").unlink()
        self.assertNotEqual(self.run_check().returncode, 0)

    def test_missing_original_or_changed_runtime_is_rejected(self) -> None:
        original = self.cuda / "bin/x64/cublas64_13.dll"
        original.unlink()
        self.assertNotEqual(self.run_check().returncode, 0)
        original.write_bytes(b"original runtime")
        (self.runtime / "bin/cublas64_13.dll").write_bytes(b"wrong runtime")
        self.assertNotEqual(self.run_check().returncode, 0)
        (self.runtime / "bin/cublas64_13.dll").write_bytes(b"original runtime")
        (self.bin / "cudnn64_9.dll").write_bytes(b"wrong bundle")
        self.assertNotEqual(self.run_check().returncode, 0)

    def test_wrong_cuda_or_cudnn_version_is_rejected(self) -> None:
        self.cuda = self.cuda.rename(self.cuda.parent / "v13.5")
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SDK version does not match", result.stderr)
        self.cuda = self.cuda.rename(self.cuda.parent / "v13.4")
        self.cudnn = self.cudnn.rename(self.cudnn.parent / "v9.28.0.0")
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SDK version does not match", result.stderr)


if __name__ == "__main__":
    unittest.main()
