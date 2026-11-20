"""Real CMake/C++ fixtures and shell transport doubles do not prove the actual CK SDK or GPU."""

import os
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
LIB = ROOT / "linux/scripts/03-media/build/migraphx"


class CKConsumerTests(unittest.TestCase):
    """Installed-target selection, exact header bytes and raw failures have independent controls."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary = tempfile.TemporaryDirectory(prefix="CK external fixture ")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        cls.prefix = cls.root / "prefix with spaces"
        cls.source = cls.root / "fixture source"
        cls.source.mkdir()
        include = cls.prefix / "include/ck/host"
        include.mkdir(parents=True)
        (include / "headers.hpp").write_text(
            "#include <string_view>\n#include <unordered_map>\n"
            "namespace ck::host { std::unordered_map<std::string_view, std::string_view> GetHeaders(); }\n")
        cls.reference = b"Independent CK fixture header\n\0tail after NUL\n"
        body = ",".join(str(x) for x in cls.reference)
        (cls.source / "fixture.cpp").write_text(
            '#include <ck/host/headers.hpp>\n#include <cstdlib>\n'
            'std::unordered_map<std::string_view, std::string_view> ck::host::GetHeaders() {\n'
            'static const char body[] = {' + body + '};\n'
            'if (std::getenv("CK_FIXTURE_MISSING")) return {};\n'
            'if (std::getenv("CK_FIXTURE_EMPTY")) return {{"ck/utility/type.hpp", ""}};\n'
            'return {{"ck/utility/type.hpp", {body, sizeof(body)}}};\n}\n')
        (cls.source / "CMakeLists.txt").write_text(
            "cmake_minimum_required(VERSION 3.20)\nproject(CKFixture LANGUAGES CXX)\n"
            "add_library(fixture STATIC fixture.cpp)\n"
            'target_include_directories(fixture PRIVATE "${CMAKE_INSTALL_PREFIX}/include")\n'
            "target_compile_features(fixture PRIVATE cxx_std_20)\n"
            'set_target_properties(fixture PROPERTIES OUTPUT_NAME ck_host ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_INSTALL_PREFIX}/lib")\n')
        cls.checked(["cmake", "-S", str(cls.source), "-B", str(cls.root / "fixture build"),
                     "-DCMAKE_INSTALL_PREFIX=" + str(cls.prefix)])
        cls.checked(["cmake", "--build", str(cls.root / "fixture build"), "--parallel", "2"])
        config = cls.prefix / "lib/cmake/composable_kernel_host"
        config.mkdir(parents=True)
        (config / "composable_kernel_host-config.cmake").write_text(
            "add_library(composable_kernel::ck_host STATIC IMPORTED)\n"
            "set_target_properties(composable_kernel::ck_host PROPERTIES\n"
            ' IMPORTED_LOCATION "${CMAKE_CURRENT_LIST_DIR}/../../libck_host.a"\n'
            ' INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_CURRENT_LIST_DIR}/../../../include")\n')
        (config / "composable_kernel_host-config-version.cmake").write_text(
            'set(PACKAGE_VERSION "1.0.0")\nset(PACKAGE_VERSION_COMPATIBLE TRUE)\n'
            "set(PACKAGE_VERSION_EXACT TRUE)\n")
        cls.consumer = cls.root / "consumer build"
        cls.checked(cls.configure(cls.prefix, cls.consumer))
        cls.checked(["cmake", "--build", str(cls.consumer), "--parallel", "2"])
        cls.binary = cls.consumer / "ck-host-consumer"

    @staticmethod
    def checked(argv: list[str]) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(argv, capture_output=True, text=True, check=False, timeout=45,
                                env=dict(os.environ, LC_ALL="C"))
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        return result

    @staticmethod
    def configure(prefix: Path, build: Path) -> list[str]:
        return ["cmake", "-S", str(LIB / "ck-host-consumer"), "-B", str(build),
                "-DCK_PREFIX=" + str(prefix), "-DCK_REQUIRED_VERSION=1.0.0",
                "-Dcomposable_kernel_host_DIR=" + str(prefix / "lib/cmake/composable_kernel_host")]

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="CK consumer case ")
        self.addCleanup(temporary.cleanup)
        self.case = Path(temporary.name)
        self.header = self.case / "original header.hpp"
        self.header.write_bytes(self.reference)

    def test_program_writes_exact_bytes_and_reports_argument_or_output_errors(self) -> None:
        output = self.case / "from real program.hpp"
        result = self.checked([str(self.binary), str(output)])
        self.assertEqual(output.read_bytes(), self.reference)
        self.assertIn("CK HOST HEADERS: 1", result.stdout)
        for argv, status in [([], 2), ([str(self.case / "absent/child")], 4)]:
            result = subprocess.run([str(self.binary), *argv], capture_output=True, check=False, timeout=10)
            self.assertEqual(result.returncode, status)

    def test_missing_or_empty_actual_api_header_fails(self) -> None:
        for name in ["CK_FIXTURE_MISSING", "CK_FIXTURE_EMPTY"]:
            output = self.case / name
            result = subprocess.run([str(self.binary), str(output)], capture_output=True, check=False,
                                    timeout=10, env=dict(os.environ, **{name: "1"}))
            self.assertEqual(result.returncode, 3)
            self.assertFalse(output.exists())

    def test_real_cmake_refuses_inexact_version_or_missing_target(self) -> None:
        for fault in ["version", "target", "package"]:
            with self.subTest(fault=fault):
                prefix = self.case / (fault + " prefix")
                shutil.copytree(self.prefix, prefix)
                config = prefix / "lib/cmake/composable_kernel_host"
                if fault == "version":
                    (config / "composable_kernel_host-config-version.cmake").write_text(
                        'set(PACKAGE_VERSION "1.1.0")\nset(PACKAGE_VERSION_COMPATIBLE TRUE)\n'
                        "set(PACKAGE_VERSION_EXACT FALSE)\n")
                elif fault == "target":
                    (config / "composable_kernel_host-config.cmake").write_text("set(CK_FIXTURE_FOUND TRUE)\n")
                else:
                    (config / "composable_kernel_host-config.cmake").unlink()
                result = subprocess.run(self.configure(prefix, self.case / fault), capture_output=True,
                                        text=True, check=False, timeout=30,
                                        env=dict(os.environ, LC_ALL="C", CMAKE_PREFIX_PATH=str(self.prefix)))
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("Parse error", result.stdout + result.stderr)
                self.assertIn("composable_kernel", result.stdout + result.stderr)

    def transport(self, fault: str = "") -> tuple[subprocess.CompletedProcess[str], Path]:
        work = self.case / ("work " + (fault or "valid"))
        text = (LIB / "verify-source-ck.sh").read_text()
        body = text[text.index("clang_root='' gcc_root=''"):]
        cache = (
            "CMAKE_CXX_COMPILER_LAUNCHER:STRING=/fixture-cache\n"
            "CMAKE_C_COMPILER_LAUNCHER:STRING=/fixture-cache\n"
            "CMAKE_CXX_COMPILER:FILEPATH=/selected clang/bin/clang++\n"
            "CMAKE_CXX_STANDARD:STRING=20\ncomposable_kernel_host_DIR:PATH="
            + str(self.prefix / "lib/cmake/composable_kernel_host") + "\n")
        callbacks = r"""
migraphx_prepare_native_work() {
  mkdir "$1"
  printf -v "$3" '%s' '/selected clang'
  printf -v "$4" '%s' '/selected gcc'
}
append_cmake_cache_linker_args() {
  CMAKE_COMPILER_CACHE_PIN=/fixture-cache
  if [[ "$FAULT" == cache ]]; then CMAKE_COMPILER_CACHE_PIN=/wrong-cache; fi
}
cmake() {
  if [[ "$1" == --build ]]; then
    [[ "$FAULT" != build ]] || return 37
    cp "$FIXTURE_BINARY" "$work/build/ck-host-consumer"
  else
    [[ "$FAULT" != configure ]] || return 37
    mkdir -p "$work/build"
    printf '%s' "$FAKE_CACHE" > "$work/build/CMakeCache.txt"
    printf '%s\0' "$@" > "$work/build/actual-argv.nul"
    if [[ "$FAULT" == import ]]; then
      printf '%s\n' "$FOREIGN_LIBRARY" > "$work/build/imported-library.txt"
    else
      printf '%s\n' "$ck_prefix/lib/libck_host.a" > "$work/build/imported-library.txt"
    fi
  fi
}
"""
        foreign = self.case / "foreign libck_host.a"
        if fault == "import":
            shutil.copyfile(self.prefix / "lib/libck_host.a", foreign)
        if fault == "compiler":
            cache = cache.replace("/selected clang/bin/clang++", "/foreign clang++")
        if fault == "standard":
            cache = cache.replace("CMAKE_CXX_STANDARD:STRING=20", "CMAKE_CXX_STANDARD:STRING=17")
        if fault == "prefix-cache":
            cache = cache.replace(str(self.prefix / "lib/cmake/composable_kernel_host"), "/foreign config")
        if fault == "bytes":
            self.header.write_bytes(b"different original bytes")
        if fault == "missing":
            self.header.unlink()
        env = dict(os.environ, LC_ALL="C", work=str(work), ck_prefix=str(self.prefix),
                   original_header=str(self.header), SCRIPT_DIR=str(LIB), MIGRAPHX_CK_HOST_VERSION="1.0.0",
                   FAULT=fault, FAKE_CACHE=cache, FIXTURE_BINARY=str(self.binary), FOREIGN_LIBRARY=str(foreign))
        if fault == "runtime":
            env["CK_FIXTURE_MISSING"] = "1"
        prelude = "set -euo pipefail\n" + "\n".join("source " + shlex.quote(str(ROOT / name)) for name in [
            "linux/scripts/01-core/cmake-cache-linker.sh",
            "linux/scripts/03-media/build/migraphx/source-common.sh"]) + "\n"
        return subprocess.run(["bash", "-c", prelude + callbacks + body], env=env, capture_output=True,
                              text=True, check=False, timeout=15), work

    def test_transport_keeps_exact_prefix_header_bytes_and_argv(self) -> None:
        result, work = self.transport()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((work / "embedded-header.hpp").read_bytes(), self.reference)
        args = (work / "build/actual-argv.nul").read_bytes().split(b"\0")
        for value in ["-DCMAKE_CXX_STANDARD=20", "-DCMAKE_CXX_COMPILER=/selected clang/bin/clang++",
                      "-DCMAKE_CXX_COMPILER_EXTERNAL_TOOLCHAIN=/selected gcc",
                      "-Dcomposable_kernel_host_DIR=" + str(self.prefix / "lib/cmake/composable_kernel_host")]:
            self.assertIn(value.encode(), args)
        self.assertIn("CK HOST EXTERNAL CONSUMER PASSED", result.stdout)

    def test_transport_retains_selected_raw_failures(self) -> None:
        for fault, status in [("configure", 37), ("build", 37), ("cache", 1), ("import", 1),
                              ("runtime", 3), ("bytes", 1), ("missing", 2),
                              ("compiler", 1), ("standard", 1), ("prefix-cache", 1)]:
            with self.subTest(fault=fault):
                self.header.write_bytes(self.reference)
                result, _work = self.transport(fault)
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                self.assertNotIn("CK HOST EXTERNAL CONSUMER PASSED", result.stdout)


    def test_entrypoint_keeps_shared_cli_and_source_scope(self) -> None:
        text = (LIB / "verify-source-ck.sh").read_text()
        self.assertIn("'NEW_WORK CK_PREFIX ORIGINAL_HEADER' 3", text)
        self.assertIn('source "${SCRIPT_DIR}/entry-common.sh"', text)
        self.assertIn('migraphx_prepare_native_work "${work}" work clang_root gcc_root', text)


if __name__ == "__main__":
    unittest.main()
