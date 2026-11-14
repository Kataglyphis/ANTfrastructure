"""Real ELF inspection with explicit compiler doubles tests guards, not HIP compilation or hardware execution."""

import os
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
LIB = ROOT / "linux/scripts/03-media/build/migraphx"
ENTRY = r"""
source "$SOURCE_COMMON"
source "$PLATFORM_LIBRARY"
LLVM_RELEASE=99.2.3
gcc_toolchain_resolve_prefix() {
  [[ "${GCC_SETUP_STATUS:-0}" == 0 ]] || return "$GCC_SETUP_STATUS"
  printf '%s' "${GCC_PREFIX-/source GCC}"
}
[[ "${IMPORT_STATUS:-0}" == 0 ]] || return "$IMPORT_STATUS"
"""
COMPILER = r"""#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == --version ]]; then printf 'clang version %s fixture\n' "${COMPILER_VERSION:-99.2.3}"; exit 0; fi
cat > "$INPUT_RECORD"
printf '%s\0' "$@" > "$ARGV_RECORD"
printf 'retained compiler diagnostic\n' >&2
[[ "${COMPILE_STATUS:-0}" == 0 ]] || exit "$COMPILE_STATUS"
cp -- "$OBJECT_FIXTURE" "${@: -1}"
"""


class MigraphxHipCompilerTests(unittest.TestCase):
    """Positive transport uses actual files and readelf; required failures stop without a passed banner."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="MIGraphX HIP compiler ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.scripts = self.root / "linux/scripts/03-media/build/migraphx"
        self.scripts.mkdir(parents=True)
        for name in ("check-hip-compiler.sh", "hip-compiler-probe.hip", "cli-common.sh", "native-check-common.sh"):
            shutil.copy2(LIB / name, self.scripts)
        for directory, names in {"lib": ("cli-value-options.sh", "log-bootstrap.sh"),
                                 "06-packaging": ("smoke-common.sh",)}.items():
            target = self.scripts.parents[2] / directory
            target.mkdir()
            for name in names:
                shutil.copy2(ROOT / "linux/scripts" / directory / name, target)
        (self.scripts / "entry-common.sh").write_text(ENTRY)
        self.clang = self.root / "source LLVM/bin"
        self.clang.mkdir(parents=True)
        self.executable("clang++", COMPILER)
        self.executable("llvm-config", '#!/bin/sh\nprintf "%s\\n" "$BUILT_BACKENDS"\nexit "${CONFIG_STATUS:-0}"\n')
        self.object = self.root / "device.o"
        self.make_elf()
        self.scratch = self.root / "scratch"
        self.scratch.mkdir()
        self.env = dict(os.environ, LC_ALL="C", TMPDIR=str(self.scratch),
                        GCC_PREFIX="/source GCC", GCC_SETUP_STATUS="0", IMPORT_STATUS="0",
                        CONFIG_STATUS="0", COMPILE_STATUS="0", COMPILER_VERSION="99.2.3",
                        MIGRAPHX_CLANG_PREFIX=str(self.clang.parent),
                        SOURCE_COMMON=str(LIB / "source-common.sh"),
                        PLATFORM_LIBRARY=str(ROOT / "linux/scripts/01-core/platform.sh"),
                        BUILT_BACKENDS="X86 AArch64 RISCV AMDGPU", OBJECT_FIXTURE=str(self.object),
                        INPUT_RECORD=str(self.root / "input.hip"), ARGV_RECORD=str(self.root / "argv.nul"))
        self.count = 0

    def executable(self, name: str, text: str) -> None:
        path = self.clang / name
        path.write_text(text)
        path.chmod(0o755)

    def make_elf(self) -> None:
        helper = ROOT / "linux/scripts/tests/synthetic-elf-fixture.sh"
        script = 'source ' + shlex.quote(str(helper)) + '\nt_write_synthetic_elf python3 "$1" "" ""\n'
        result = subprocess.run(["bash", "-c", script, "_", str(self.object)],
                                capture_output=True, text=True, check=False, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = bytearray(self.object.read_bytes())
        payload[18:20] = (224).to_bytes(2, "little")
        self.object.write_bytes(payload)

    def probe(self, args: list[str] | None = None) -> tuple[subprocess.CompletedProcess[str], Path]:
        self.count += 1
        work = self.root / ("work " + str(self.count))
        argv = [str(work), "/ROCm SDK with spaces"] if args is None else args
        result = subprocess.run(["bash", str(self.scripts / "check-hip-compiler.sh"), *argv],
                                env=self.env, capture_output=True, text=True, check=False, timeout=15)
        self.assertEqual(list(self.scratch.iterdir()), [])
        return result, work

    def test_exact_source_compiler_hip_flags_and_real_AMDGPU_object_verdict(self) -> None:
        result, work = self.probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("HIP DEVICE COMPILER PASSED", result.stdout)
        self.assertEqual((work / "hip-machine.txt").read_text(), "AMD GPU\n")
        self.assertEqual((work / "hip-device.o").read_bytes(), self.object.read_bytes())
        self.assertTrue((work / "hip-object.sha256").is_file())
        argv = (self.root / "argv.nul").read_bytes().split(b"\0")[:-1]
        for option in (b"--gcc-toolchain=/source GCC", b"--rocm-path=/ROCm SDK with spaces",
                       b"-I/ROCm SDK with spaces/include", b"--cuda-device-only", b"--offload-arch=gfx1030"):
            self.assertEqual(argv.count(option), 1)
        self.assertEqual(argv[argv.index(b"-x") + 1], b"hip")
        self.assertEqual((work / "hip-argv.nul").read_bytes().split(b"\0")[0], str(self.clang / "clang++").encode())
        program = (self.root / "input.hip").read_text()
        for token in ("hip/hip_runtime.h", "__global__", "threadIdx.x", "__builtin_sqrtf"):
            self.assertIn(token, program)

    def test_missing_or_partial_backend_names_refuse_before_compile(self) -> None:
        for backends in ("X86 AArch64 RISCV", "X86 NotAMDGPU", "AMDGPUExtra", ""):
            self.env["BUILT_BACKENDS"] = backends
            result, _work = self.probe()
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("lacks the AMDGPU backend", result.stderr)
            self.assertFalse((self.root / "input.hip").exists())

    def test_multiline_backend_tokens_are_supported(self) -> None:
        self.env["BUILT_BACKENDS"] = "X86\nAMDGPU\tRISCV"
        self.assertEqual(self.probe()[0].returncode, 0)

    def test_failed_configuration_and_compilation_keep_raw_status_and_diagnostics(self) -> None:
        self.env["CONFIG_STATUS"] = "41"
        self.assertEqual(self.probe()[0].returncode, 41)
        self.env["CONFIG_STATUS"] = "0"
        self.env["COMPILE_STATUS"] = "47"
        result, work = self.probe()
        self.assertEqual(result.returncode, 47, result.stderr)
        self.assertIn("retained compiler diagnostic", result.stderr)
        self.assertEqual((work / "hip-status.txt").read_text(), "47\n")
        self.assertNotIn("HIP DEVICE COMPILER PASSED", result.stdout)
        self.assertFalse((work / "hip-device.o").exists())

    def test_native_or_invalid_objects_cannot_pass(self) -> None:
        original = bytearray(self.object.read_bytes())
        original[18:20] = (62).to_bytes(2, "little")
        for payload in (bytes(original), b"not an ELF"):
            self.object.write_bytes(payload)
            result, work = self.probe()
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("HIP DEVICE COMPILER PASSED", result.stdout)
            self.assertFalse((work / "hip-device.o").exists())

    def test_wrong_compiler_pin_and_argument_counts_refuse_before_compilation(self) -> None:
        self.env["COMPILER_VERSION"] = "99.2.2"
        self.assertNotEqual(self.probe()[0].returncode, 0)
        self.assertFalse((self.root / "input.hip").exists())
        for args in ([], ["work"], ["work", "SDK", "extra"]):
            self.assertEqual(self.probe(args)[0].returncode, 2)

    def test_shared_preparation_retains_required_failures_under_conditional_source(self) -> None:
        for name, status in (("IMPORT_STATUS", "29"), ("GCC_SETUP_STATUS", "61")):
            env = {**self.env, name: status}
            work = self.root / name
            command = ['bash', '-c', 'set -u; status=0; source "$1" "${@:2}" || status=$?; exit "$status"',
                       '_', str(self.scripts / "native-check-common.sh"), str(work), '/ROCm SDK']
            result = subprocess.run(command, env=env, capture_output=True, text=True, check=False, timeout=15)
            self.assertEqual(result.returncode, int(status), result.stderr)
            if name == "IMPORT_STATUS":
                self.assertFalse(work.exists())
            self.assertFalse((self.root / "input.hip").exists())

    def test_empty_ROCm_or_compiler_bindings_cannot_start_the_device_probe(self) -> None:
        self.env["GCC_PREFIX"] = ""
        self.assertNotEqual(self.probe()[0].returncode, 0)
        self.env.pop("GCC_PREFIX")
        result, _work = self.probe([str(self.root / "empty SDK work"), ""])
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "input.hip").exists())

    def test_existing_work_is_never_overwritten(self) -> None:
        existing = self.root / "existing"
        existing.mkdir()
        marker = existing / "keep"
        marker.write_text("preserve")
        result, _work = self.probe([str(existing), "/ROCm SDK"])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(marker.read_text(), "preserve")
        self.assertFalse((self.root / "input.hip").exists())


if __name__ == "__main__":
    unittest.main()
