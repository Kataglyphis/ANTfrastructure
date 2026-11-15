"""Exercise build receipts and failures without compiling ORT or proving runtime registration."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
import warnings
import zipfile
from pathlib import Path
from typing import TypedDict, Unpack
from unittest.mock import patch

SUBJECT = Path(sys.argv[1]).resolve()
ELF = Path(sys.argv[2]).read_bytes()
COMMON = Path(sys.argv[3]).resolve()
REVISION = "a" * 40
FLAGS = ("onnxruntime_USE_WEBGPU", "onnxruntime_USE_EP_API_ADAPTERS",
         "onnxruntime_WEBGPU_STATIC_PLUGIN", "onnxruntime_USE_EXTERNAL_DAWN")
RECEIPT = "ort-webgpu-build.json"


class RecordOptions(TypedDict, total=False):
    mode: str
    revision: str
    source_ref: str
    without_wheel: bool


class BuildProofTests(unittest.TestCase):
    def setUp(self) -> None:
        self.workspace = tempfile.TemporaryDirectory(prefix="webgpu proof ")
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        self.prefix = self.root / "installed prefix"
        (self.prefix / "lib").mkdir(parents=True)
        self.library = self.prefix / "lib/libonnxruntime.so"
        self.library.write_bytes(ELF + b"native core")
        self.config = self.root / "configured build"
        self.config.mkdir()
        self.write_config()
        self.wheel("gil")

    def write_config(self, mode: str = "ON") -> None:
        (self.config / "CMakeCache.txt").write_text("".join(f"{name}:BOOL={mode}\n" for name in FLAGS))

    def wheel(self, phase: str, *, member: str | None = None, duplicate: bool = False,
              content: bytes | None = None, linked: bool = False) -> Path:
        folder = self.prefix / ("wheels" if phase == "gil" else "wheels-free-threaded")
        folder.mkdir(exist_ok=True)
        abi = "cp315" + ("t" if phase == "free-threaded" else "")
        path = folder / f"onnxruntime-1.31.1-cp315-{abi}-linux_x86_64.whl"
        name = member or f"onnxruntime/capi/onnxruntime_pybind11_state.cpython-315{abi[5:]}-x86_64-linux-gnu.so"
        entry = zipfile.ZipInfo(name)
        entry.external_attr = (stat.S_IFLNK | 0o777) << 16 if linked else (stat.S_IFREG | 0o644) << 16
        with warnings.catch_warnings(), zipfile.ZipFile(path, "w") as archive:
            warnings.simplefilter("ignore", UserWarning)
            archive.writestr(entry, ELF + phase.encode() if content is None else content)
            if duplicate:
                archive.writestr(entry, ELF + b"duplicate")
        return path

    def run_record(self, phase: str = "gil", *, mode: str = "ON", revision: str = REVISION,
                   source_ref: str = "v1.31.1", without_wheel: bool = False) -> subprocess.CompletedProcess[str]:
        command = [sys.executable, str(SUBJECT), "--prefix", str(self.prefix), "--cmake-dir", str(self.config),
                   "--phase", phase, "--expected", mode, "--source-ref", source_ref, "--source-revision", revision]
        if without_wheel:
            command.append("--without-wheel")
        return subprocess.run(command, capture_output=True, text=True, check=False, timeout=20)

    def passed(self, phase: str = "gil", **options: Unpack[RecordOptions]) -> dict:
        result = self.run_record(phase, **options)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads((self.prefix / RECEIPT).read_text())

    def failed(self, phase: str = "gil", **options: Unpack[RecordOptions]) -> None:
        receipt = self.prefix / RECEIPT
        previous = receipt.read_bytes() if receipt.exists() else None
        result = self.run_record(phase, **options)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(receipt.read_bytes() if receipt.exists() else None, previous)

    def test_separate_products_keep_their_own_bytes_and_configurations(self) -> None:
        for mode in ("ON", "OFF"):
            with self.subTest(mode=mode):
                self.write_config(mode)
                receipt = self.passed(mode=mode)
                self.assertEqual(receipt["source"], {"ref": "v1.31.1", "revision": REVISION})
                native, gil = receipt["phases"]["gil"]["products"]
                self.assertEqual(native["sha256"], hashlib.sha256(self.library.read_bytes()).hexdigest())
                self.assertEqual(gil["sha256"], hashlib.sha256(ELF + b"gil").hexdigest())
                self.wheel("free-threaded")
                receipt = self.passed("free-threaded", mode=mode)
                ft = receipt["phases"]["free-threaded"]["products"][0]
                self.assertEqual(ft["sha256"], hashlib.sha256(ELF + b"free-threaded").hexdigest())
                self.assertNotEqual(ft["sha256"], gil["sha256"])
                for phase in receipt["phases"].values():
                    self.assertEqual(phase["configured_flags"], dict.fromkeys(FLAGS, mode))
                    self.assertEqual(phase["cmake_cache_sha256"], hashlib.sha256((self.config / "CMakeCache.txt").read_bytes()).hexdigest())

    def test_crlf_cache_is_accepted(self) -> None:
        cache = self.config / "CMakeCache.txt"
        cache.write_bytes(cache.read_bytes().replace(b"\n", b"\r\n"))
        self.passed()

    def test_each_missing_wrong_typed_disabled_or_duplicate_flag_fails(self) -> None:
        original = (self.config / "CMakeCache.txt").read_text()
        for flag in FLAGS:
            line = f"{flag}:BOOL=ON\n"
            for replacement in ("", f"{flag}:BOOL=OFF\n", f"{flag}:STRING=ON\n", line + line):
                with self.subTest(flag=flag, replacement=replacement):
                    (self.config / "CMakeCache.txt").write_text(original.replace(line, replacement))
                    self.failed()
        (self.config / "CMakeCache.txt").unlink()
        self.failed()

    def test_missing_core_and_a_core_outside_its_prefix_fail(self) -> None:
        self.library.unlink()
        self.failed()
        outside = self.root / "foreign core.so"
        outside.write_bytes(ELF)
        self.library.symlink_to(outside)
        self.failed()

    def test_invalid_core_and_binding_bytes_fail(self) -> None:
        for payload in (b"", b"not an ELF"):
            with self.subTest(payload=payload):
                self.library.write_bytes(payload)
                self.failed()
                self.library.write_bytes(ELF)
                self.wheel("gil", content=payload)
                self.failed()

    def test_a_no_wheel_native_build_requires_an_explicit_empty_store(self) -> None:
        self.failed(without_wheel=True)
        shutil.rmtree(self.prefix / "wheels")
        self.failed()
        receipt = self.passed(without_wheel=True)
        self.assertEqual([p["kind"] for p in receipt["phases"]["gil"]["products"]], ["native-core"])
        self.failed("free-threaded", without_wheel=True)

    def test_ambiguous_missing_duplicate_linked_and_foreign_wheel_members_fail(self) -> None:
        cases = (("foreign/module.so", False, False), (None, True, False), (None, False, True))
        for member, duplicate, linked in cases:
            with self.subTest(member=member, duplicate=duplicate, linked=linked):
                self.wheel("gil", member=member, duplicate=duplicate, linked=linked)
                self.failed()
        wheel = self.wheel("gil")
        shutil.copyfile(wheel, wheel.with_name(wheel.name.replace("1.31.1", "1.30.0")))
        self.failed()

    def test_wheel_abi_and_package_name_are_checked(self) -> None:
        wheel = self.wheel("gil")
        for changed in (wheel.name.replace("-cp315-linux", "-cp315t-linux"), wheel.name.replace("onnxruntime-", "foreign-")):
            renamed = wheel.with_name(changed)
            wheel.rename(renamed)
            self.failed()
            renamed.rename(wheel)

    def test_free_threaded_requires_the_same_native_source_mode_and_products(self) -> None:
        self.wheel("free-threaded")
        self.failed("free-threaded")
        self.passed()
        self.failed("free-threaded", revision="b" * 40)
        self.failed("free-threaded", source_ref="another-ref")
        self.write_config("OFF")
        self.failed("free-threaded", mode="OFF")
        self.write_config()
        original = self.library.read_bytes()
        self.library.write_bytes(original + b"stale")
        self.failed("free-threaded")
        self.library.write_bytes(original)
        self.wheel("gil", content=ELF + b"stale binding")
        self.failed("free-threaded")

    def test_repeated_ft_and_corrupt_receipts_fail(self) -> None:
        self.wheel("free-threaded")
        self.passed()
        self.passed("free-threaded")
        self.failed("free-threaded")
        (self.prefix / RECEIPT).write_text("{broken")
        self.failed("free-threaded")

    def test_invalid_source_identity_fails(self) -> None:
        self.failed(revision="short")
        self.failed(source_ref="")

    def test_failed_atomic_publication_leaves_old_receipt_and_no_scratch(self) -> None:
        self.passed()
        before = (self.prefix / RECEIPT).read_bytes()
        spec = importlib.util.spec_from_file_location("webgpu_build_proof", SUBJECT)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with patch.object(module.os, "replace", side_effect=OSError("fixture refusal")), self.assertRaises(OSError):
            module.write_receipt(self.prefix, {"new": "data"})
        self.assertEqual((self.prefix / RECEIPT).read_bytes(), before)
        self.assertEqual({p.name for p in self.prefix.iterdir()}, {"lib", "wheels", RECEIPT})

    def test_shared_shell_recorder_preserves_failures_optouts_and_required_companion(self) -> None:
        harness = COMMON.parents[5] / "tests/test-harness.sh"
        emitted = subprocess.run(["bash", "-c", 'source "$1"; t_fn_src "$2" record_onnx_webgpu_build_products',
                                  "fixture", str(harness), str(COMMON)], capture_output=True, text=True, check=True)
        program = """set -euo pipefail
_ONNX_LIB_DIR="$1"; ORT_SRC_DIR="$2"; ORT_VERSION=v1.31.1
onnx_webgpu_enabled_for_target() { [ "$WANT_MODE" = ON ]; }
assert_onnx_webgpu_static_plugin() { return "$GATE_RC"; }
git() { [ "$1" = -C ] && [ "$2" = "$ORT_SRC_DIR" ] || return 29; [ "$GIT_RC" = 0 ] || return "$GIT_RC"; printf '%s\n' "$SOURCE_REVISION"; }
BUILD_ARGS=('--build_wheel' 'value with spaces')
if [ "$NO_WHEEL" = 1 ]; then BUILD_ARGS=('value with spaces'); fi
""" + emitted.stdout + '\nrecord_onnx_webgpu_build_products "$3" "$4" gil BUILD_ARGS\n'
        environment = {**os.environ, "WANT_MODE": "ON", "GATE_RC": "0", "GIT_RC": "0",
                       "SOURCE_REVISION": REVISION, "NO_WHEEL": "0"}
        command = ["bash", "-c", program, "fixture", str(SUBJECT.parent), str(self.root), str(self.config), str(self.prefix)]
        for changes, expected in (({}, 0), ({"GATE_RC": "27"}, 27), ({"GIT_RC": "31"}, 31)):
            result = subprocess.run(command, env={**environment, **changes}, capture_output=True, text=True, check=False, timeout=20)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        command[4] = str(self.root / "missing companion")
        result = subprocess.run(command, env=environment, capture_output=True, text=True, check=False, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        command[4] = str(SUBJECT.parent)
        self.write_config("OFF")
        shutil.rmtree(self.prefix / "wheels")
        result = subprocess.run(command, env={**environment, "WANT_MODE": "OFF", "NO_WHEEL": "1"},
                                capture_output=True, text=True, check=False, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        receipt = json.loads((self.prefix / RECEIPT).read_text())
        self.assertEqual(receipt["phases"]["gil"]["configured_flags"], dict.fromkeys(FLAGS, "OFF"))
        self.assertEqual(len(receipt["phases"]["gil"]["products"]), 1)

    def test_cpu_and_nvidia_record_before_reconfiguring_and_stop_on_proof_failure(self) -> None:
        for script in ("30-build-native.sh", "30-build-native-nvidia.sh"):
            source = (COMMON.parent.parent / script).read_text()
            self.assertIn("record_onnx_webgpu_build_products ", source)
            tail = source[source.index("record_onnx_webgpu_build_products "):]
            for result in (0, 19):
                with self.subTest(script=script, result=result):
                    program = """set -euo pipefail
NATIVE_CPU_BUILD_DIR='/fixture/CPU build'; NATIVE_GPU_BUILD_DIR='/fixture/GPU build'
NATIVE_CPU_OUTPUT_DIR='/fixture/CPU output'; NATIVE_GPU_OUTPUT_DIR='/fixture/GPU output'
NATIVE_CPU_CONFIG=Release; BUILD_ARGS=('--build_wheel' 'argument with spaces')
record_onnx_webgpu_build_products() { printf 'RECORD <%s> <%s> <%s> <%s>\n' "$@"; return "$PROOF_RC"; }
onnx_build_free_threaded_wheel() { printf 'FT <%s> <%s> <%s> <%s>\n' "$@"; }
err() { printf 'ERR %s\n' "$*"; exit 23; }
""" + tail
                    done = subprocess.run(["bash", "-c", program], env={**os.environ, "PROOF_RC": str(result)},
                                          capture_output=True, text=True, check=False, timeout=20)
                    self.assertEqual(done.returncode, 0 if result == 0 else 23, done.stderr)
                    self.assertIn("<gil> <BUILD_ARGS>", done.stdout)
                    self.assertEqual("FT <" in done.stdout, result == 0)
                    if result == 0:
                        self.assertLess(done.stdout.index("RECORD <"), done.stdout.index("FT <"))


if __name__ == "__main__":
    unittest.main(argv=[__file__], verbosity=2)
