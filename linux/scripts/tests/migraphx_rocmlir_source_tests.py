"""Shell source and notice controls with command doubles; no vendor build or binary licence closure proof."""

import hashlib
import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
LIB = ROOT / "linux/scripts/03-media/build/migraphx"
PRIMARY = ("LICENSE", "external/llvm-project/LICENSE.TXT", "external/triton/LICENSE")
SOURCE_FILES = ("external/llvm-project/llvm/CMakeLists.txt", "external/llvm-project/mlir/CMakeLists.txt", "external/llvm-project/lld/CMakeLists.txt", "external/triton/CMakeLists.txt", "cmake/triton.cmake")


class MigraphxRocmlirSourceTests(unittest.TestCase):
    """Real file transport and independent argv expectations reject weakened source preparation."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="rocMLIR source ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.tree = self.root / "original source"
        self.tree.mkdir()
        self.files = dict.fromkeys(SOURCE_FILES, b"source placeholder\n")
        self.files["CMakeLists.txt"] = b"project(rocMLIR VERSION 2.0.0 LANGUAGES CXX C)\n"
        self.files.update({name: (name + "\r\noriginal text\n").encode() for name in PRIMARY})
        self.files["notice with spaces.txt"] = b"unchanged bytes\r\n"
        for name, raw in self.files.items():
            path = self.tree / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(raw)
        self.policy = self.root / "original policy"
        self.policy.write_text("# Original input bytes\n" + "".join(
            hashlib.sha256(self.files[name]).hexdigest() + "  " + name + "\n"
            for name in (*PRIMARY, "notice with spaces.txt")
        ))
        self.calls = 0

    def shell(self, body: str) -> subprocess.CompletedProcess[str]:
        imports = [ROOT / "linux/scripts/01-core/downloads.sh", LIB / "source-common.sh", LIB / "source-rocmlir.sh"]
        prelude = "set -euo pipefail\n" + "".join("source " + shlex.quote(str(path)) + "\n" for path in imports)
        return subprocess.run(["bash", "-c", prelude + body], check=False, capture_output=True,
                              text=True, timeout=15, env=dict(os.environ, LC_ALL="C", MIGRAPHX_ROCMLIR_VERSION="2.0.0"))

    def stage(self, prefix: str = "") -> tuple[subprocess.CompletedProcess[str], Path]:
        self.calls += 1
        dest = self.root / ("staged " + str(self.calls))
        call = shlex.join(["migraphx_stage_rocmlir_notices", str(self.tree), str(dest), str(self.policy)])
        return self.shell(prefix + 'status=0\n' + call + ' || status=$?\nexit "$status"\n'), dest

    def test_exact_version_and_each_vendored_source_are_required(self) -> None:
        command = 'status=0\n' + shlex.join(["migraphx_rocmlir_source_contract", str(self.tree)]) + ' || status=$?\nexit "$status"\n'
        self.assertEqual(self.shell(command).returncode, 0)
        for name in ("CMakeLists.txt", *SOURCE_FILES):
            path = self.tree / name
            original = path.read_bytes()
            path.unlink()
            try:
                self.assertEqual(self.shell(command).returncode, 2 if name == "CMakeLists.txt" else 1, name)
            finally:
                path.write_bytes(original)
        (self.tree / "CMakeLists.txt").write_text("project(rocMLIR VERSION 2.1.0 LANGUAGES CXX C)\n")
        self.assertEqual(self.shell(command).returncode, 1)

    def test_original_notice_bytes_and_policy_are_preserved(self) -> None:
        result, dest = self.stage()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for name in (*PRIMARY, "notice with spaces.txt"):
            self.assertEqual((dest / name).read_bytes(), self.files[name])
            self.assertEqual((self.tree / name).read_bytes(), self.files[name])
        self.assertEqual((dest / "SOURCE-NOTICE-SHA256SUMS").read_bytes(), self.policy.read_bytes())
        reused = self.shell(shlex.join([
            "migraphx_stage_rocmlir_notices", str(self.tree), str(dest), str(self.policy),
        ]))
        self.assertEqual(reused.returncode, 1)

    def test_hash_mismatch_never_deletes_or_changes_original_source(self) -> None:
        self.policy.write_text(self.policy.read_text().replace(hashlib.sha256(self.files["LICENSE"]).hexdigest(), "0" * 64))
        result, dest = self.stage()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual((self.tree / "LICENSE").read_bytes(), self.files["LICENSE"])
        self.assertFalse((dest / "SOURCE-NOTICE-SHA256SUMS").exists())

    def test_empty_incomplete_missing_and_invalid_policy_refuse(self) -> None:
        original = self.policy.read_text()
        for text, status in [
            ("# comment only\n", 1), ("z" * 64 + "  LICENSE\n", 2),
            ("a" * 64 + "  /absolute\n", 2), ("a" * 64 + "  ../escape\n", 2),
            ("a" * 64 + "  dir/../escape\n", 2), ("a" * 64 + "\n", 2),
            ("a" * 64 + "  dir/..\n", 2),
            (original.splitlines()[1] + "\n", 1),
            ("a" * 64 + "  absent-original\n", 1),
        ]:
            with self.subTest(policy=text):
                self.policy.write_text(text)
                result, dest = self.stage()
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                self.assertFalse((dest / "SOURCE-NOTICE-SHA256SUMS").exists())
        for missing in PRIMARY:
            self.policy.write_text("\n".join(line for line in original.splitlines() if not line.endswith("  " + missing)) + "\n")
            self.assertEqual(self.stage()[0].returncode, 1, missing)
        self.policy.unlink()
        self.assertEqual(self.stage()[0].returncode, 1)

    def test_copy_and_hash_failures_keep_raw_status(self) -> None:
        for stub, expected in [
            ("cp() { return 36; }\n", 36),
            ("download_verify_sha256() { return 37; }\n", 37),
        ]:
            result, dest = self.stage(stub)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
            self.assertFalse((dest / "SOURCE-NOTICE-SHA256SUMS").exists())
            self.assertEqual((self.tree / "LICENSE").read_bytes(), self.files["LICENSE"])

    def plan(self, prefix: str = "") -> tuple[subprocess.CompletedProcess[str], Path]:
        self.calls += 1
        work = self.root / ("plan " + str(self.calls))
        work.mkdir()
        body = r"""
append_cmake_cache_linker_args() {
  local -n fixture_args="$1"
  fixture_args+=('-DCMAKE_C_COMPILER_LAUNCHER=/fixture cache' '-DCMAKE_CXX_COMPILER_LAUNCHER=/fixture cache')
  CMAKE_COMPILER_CACHE_PIN='/fixture cache'
}
declare -a selected=('stale option')
""" + prefix + shlex.join([
            "migraphx_rocmlir_cmake_plan", "selected", str(work), "/ROCm with spaces",
            "/source clang", "/source GCC", "/host python",
        ]) + '\nprintf "%s\\n" "${CMAKE_COMPILER_CACHE_PIN:-}"\n'
        return self.shell(body), work

    def test_independent_fat_static_pic_offline_source_compiler_plan(self) -> None:
        result, work = self.plan()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        raw = (work / "cmake-argv.nul").read_bytes()
        self.assertTrue(raw.endswith(b"\0"))
        args = raw.split(b"\0")[:-1]
        expected = [
            "-DBUILD_FAT_LIBROCKCOMPILER:BOOL=ON", "-DBUILD_SHARED_LIBS:BOOL=OFF",
            "-DCMAKE_POSITION_INDEPENDENT_CODE:BOOL=ON", "-DLLVM_TARGETS_TO_BUILD=X86;AMDGPU",
            "-DLLVM_INCLUDE_TESTS:BOOL=OFF", "-DMLIR_INCLUDE_TESTS:BOOL=OFF",
            "-DMLIR_ENABLE_ROCM_RUNNER:BOOL=OFF", "-DTRITON_OFFLINE_BUILD:BOOL=ON",
            "-DFETCHCONTENT_FULLY_DISCONNECTED:BOOL=ON", "-DFETCHCONTENT_UPDATES_DISCONNECTED:BOOL=ON",
            "-DCMAKE_C_COMPILER=/source clang/bin/clang", "-DCMAKE_CXX_COMPILER=/source clang/bin/clang++",
            "-DCMAKE_C_COMPILER_EXTERNAL_TOOLCHAIN=/source GCC",
            "-DCMAKE_CXX_COMPILER_EXTERNAL_TOOLCHAIN=/source GCC",
            "-DCMAKE_C_COMPILER_LAUNCHER=/fixture cache", "-DCMAKE_CXX_COMPILER_LAUNCHER=/fixture cache",
            "-DROCM_PATH=/ROCm with spaces", "-DPython_EXECUTABLE=/host python", "-DPython3_EXECUTABLE=/host python",
            f"-DCMAKE_INSTALL_PREFIX={work}/host-deps", f"-DTRITON_CACHE_PATH={work}/triton-cache",
            f"-DCMAKE_PREFIX_PATH={work}/host-tools;/ROCm with spaces;/ROCm with spaces/core;/ROCm with spaces/core/lib/rocm_sysdeps",
            f"-DROCmCMakeBuildTools_DIR={work}/host-tools/share/rocmcmakebuildtools/cmake",
        ]
        for value in expected:
            self.assertIn(value.encode(), args)
        self.assertEqual(args[:6], [b"-S", str(work / "source").encode(), b"-B", str(work / "build").encode(), b"-G", b"Ninja"])
        self.assertNotIn(b"stale option", args)
        self.assertEqual(result.stdout.strip(), "/fixture cache")

    def test_plan_cache_selection_failure_stops_before_recording(self) -> None:
        result, work = self.plan("append_cmake_cache_linker_args() { return 37; }\n")
        self.assertEqual(result.returncode, 37, result.stdout + result.stderr)
        self.assertFalse((work / "cmake-argv.nul").exists())

    def test_entry_uses_verified_transport_before_configure_and_requires_cache_facts(self) -> None:
        source = (LIB / "prepare-source-rocmlir.sh").read_text()
        ordered = [
            'source "${SCRIPT_DIR}/entry-common.sh"', 'source "${SCRIPT_DIR}/source-rocmlir.sh"',
            "migraphx_prepare_native_work", "migraphx_prepare_source_tree",
            "migraphx_rocmlir_source_contract", "migraphx_stage_rocmlir_notices",
            "migraphx_prepare_rocm_cmake", "setup_host_python_environment",
            "migraphx_rocmlir_cmake_plan", 'cmake "${cmake_args[@]}"',
            "cmake_assert_compiler_cache_pin", "cmake_assert_configured_entries",
            "ROCMLIR SOURCE CONFIGURED:",
        ]
        positions = [source.index(value) for value in ordered]
        self.assertEqual(positions, sorted(positions))
        self.assertIn('"${MIGRAPHX_ROCMLIR_SOURCE_SHA256}"', source)
        self.assertIn('"${SCRIPT_DIR}/rocmlir-source-notices.sha256"', source)
        self.assertNotIn("cmake --build", source)
        self.assertNotIn("cmake --install", source)
        for value in [
            "BUILD_FAT_LIBROCKCOMPILER=ON", "BUILD_SHARED_LIBS=OFF", "CMAKE_POSITION_INDEPENDENT_CODE=ON",
            "LLVM_INCLUDE_TESTS=OFF", "MLIR_INCLUDE_TESTS=OFF", "MLIR_ENABLE_ROCM_RUNNER=OFF",
            "TRITON_OFFLINE_BUILD=ON", "FETCHCONTENT_FULLY_DISCONNECTED=ON",
            "CMAKE_C_COMPILER=${clang_root}/bin/clang", "CMAKE_CXX_COMPILER=${clang_root}/bin/clang++",
            "CMAKE_INSTALL_PREFIX=${work}/host-deps", "LLVM_TARGETS_TO_BUILD=X86;AMDGPU",
        ]:
            self.assertIn(value, source)

    def test_entry_rejects_bad_arity_before_bootstrap(self) -> None:
        for args in [[], ["work"], ["work", "archive", "rocm"], ["work", "archive", "tools", "rocm", "extra"]]:
            result = subprocess.run(["bash", str(LIB / "prepare-source-rocmlir.sh"), *args], check=False,
                                    capture_output=True, text=True, timeout=10, env=dict(os.environ, LC_ALL="C"))
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)

    def test_actual_cache_verdict_rejects_each_missing_or_wrong_fact(self) -> None:
        work = self.root / "configured work"
        build = work / "build"
        build.mkdir(parents=True)
        values = dict.fromkeys([
            "BUILD_FAT_LIBROCKCOMPILER", "CMAKE_POSITION_INDEPENDENT_CODE", "TRITON_OFFLINE_BUILD",
            "FETCHCONTENT_FULLY_DISCONNECTED", "FETCHCONTENT_UPDATES_DISCONNECTED",
        ], ("BOOL", "ON"))
        values.update(dict.fromkeys([
            "BUILD_SHARED_LIBS", "LLVM_INCLUDE_TESTS", "MLIR_INCLUDE_TESTS", "MLIR_ENABLE_ROCM_RUNNER",
        ], ("BOOL", "OFF")))
        values.update({name: ("STRING", value) for name, value in {
            "CMAKE_C_COMPILER": "/source clang/bin/clang",
            "CMAKE_CXX_COMPILER": "/source clang/bin/clang++",
            "CMAKE_C_COMPILER_LAUNCHER": "/fixture cache", "CMAKE_CXX_COMPILER_LAUNCHER": "/fixture cache",
            "CMAKE_INSTALL_PREFIX": str(work / "host-deps"), "LLVM_TARGETS_TO_BUILD": "X86;AMDGPU",
        }.items()})
        source = (LIB / "prepare-source-rocmlir.sh").read_text()
        assertions = source[source.index("cmake_assert_compiler_cache_pin"):source.index("printf 'ROCMLIR SOURCE CONFIGURED")]
        setup = "source " + shlex.quote(str(ROOT / "linux/scripts/01-core/cmake-cache-linker.sh")) + "\n"
        setup += "work=" + shlex.quote(str(work)) + "\n"
        setup += "clang_root='/source clang'\ngcc_root='/source GCC'\nCMAKE_COMPILER_CACHE_PIN='/fixture cache'\n"
        for missing in [None, *values]:
            for wrong in ([False] if missing is None else [False, True]):
                selected = dict(values)
                if missing:
                    kind = selected.pop(missing)[0]
                    if wrong:
                        selected[missing] = (kind, "invalid-value")
                (build / "CMakeCache.txt").write_text("".join(
                    f"{name}:{kind}={value}\n" for name, (kind, value) in selected.items()
                ))
                result = self.shell(setup + assertions)
                self.assertEqual(result.returncode, 0 if missing is None else 1, (missing, wrong, result.stderr))


if __name__ == "__main__":
    unittest.main()
