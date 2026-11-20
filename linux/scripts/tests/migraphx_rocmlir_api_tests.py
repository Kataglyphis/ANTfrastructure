"""Original C API declarations with a tiny compiled implementation double; no real rocMLIR or GPU acceptance."""

import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
LIB = ROOT / "linux/scripts/03-media/build/migraphx"
FIXTURE = ROOT / "linux/scripts/tests/fixtures/rocmlir-c-api"
TRACE = ["registry", "dialects", "passes", "context", "registry-destroy", "handle", "load", "namespace",
         "manager", "pipeline", "as-op", "print", "manager-destroy", "context-destroy"]


class RocmlirAPIConsumerTests(unittest.TestCase):
    """Exact exports, original selected headers and observable C API state have independent controls."""

    @classmethod
    def setUpClass(cls) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="rocMLIR API fixture ")
        cls.addClassCleanup(temporary.cleanup)
        cls.root = Path(temporary.name)
        cls.prefix = cls.root / "prefix with spaces"
        cls.original = cls.root / "original source"
        manifest = json.loads((FIXTURE / "source-manifest.json").read_text())
        if manifest["commit"] != "f347064fea12aa0ab325e1244b65766652a2530c":
            raise AssertionError("Unexpected original declaration source")
        for name, record in manifest["files"].items():
            raw = (FIXTURE / record["fixture"]).read_bytes()
            if hashlib.sha256(raw).hexdigest() != record["sha256"]:
                raise AssertionError("Original fixture bytes changed: " + name)
            target = cls.original / record["original"]
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw)
            if name.startswith("mlir-c/"):
                directory = "include/rocmlir/external/include" if name in {
                    "mlir-c/IR.h", "mlir-c/Pass.h", "mlir-c/Support.h",
                } else "include/rocmlir"
                target = cls.prefix / directory / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(raw)
        pins = (ROOT / "linux/scripts/01-core/versions.env").read_text()
        version = re.search(r"(?m)^MIGRAPHX_ROCMLIR_VERSION=(\S+)$", pins)
        api_version = re.search(r"(?m)^MIGRAPHX_ROCMLIR_DIALECT_API_VERSION=(\d+)$", pins)
        if version is None or api_version is None:
            raise AssertionError("Required rocMLIR fixture pins are missing")
        cls.version = version[1]
        cls.api_version = api_version[1]
        cls.scripts = cls.root / "script directory"
        cls.scripts.mkdir()
        rows = []
        for name in ["LICENSE", "external/llvm-project/LICENSE.TXT", "external/triton/LICENSE"]:
            raw = (cls.original / name).read_bytes()
            path = cls.prefix / "share/licenses/rocmlir" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(raw)
            rows.append(hashlib.sha256(raw).hexdigest() + "  " + name)
        policy = "\n".join(rows) + "\n"
        (cls.scripts / "rocmlir-source-notices.sha256").write_text(policy)
        (cls.prefix / "share/licenses/rocmlir/SOURCE-NOTICE-SHA256SUMS").write_text(policy)
        cls.make_library()
        config = cls.prefix / "lib/cmake/rocmlir"
        (config / "rocmlir-config.cmake").write_text('include("${CMAKE_CURRENT_LIST_DIR}/rocmlir-targets.cmake")\n')
        cls.consumer = cls.root / "consumer build"
        cls.checked(cls.configure(cls.prefix, cls.consumer))
        cls.checked(["cmake", "--build", str(cls.consumer), "--parallel", "2"])
        cls.binary = cls.consumer / "rocmlir-host-consumer"

    @classmethod
    def make_library(cls) -> None:
        source = cls.root / "fixture project"
        source.mkdir()
        shutil.copy2(FIXTURE / "runtime.cpp", source / "runtime.cpp")
        (cls.prefix / "lib/cmake/rocmlir").mkdir(parents=True)
        (source / "CMakeLists.txt").write_text(
            "cmake_minimum_required(VERSION 3.20)\nproject(RocmlirFixture LANGUAGES CXX)\n"
            "add_library(fixture STATIC runtime.cpp)\n"
            "target_compile_features(fixture PRIVATE cxx_std_17)\n"
            'target_include_directories(fixture PRIVATE "${CMAKE_INSTALL_PREFIX}/include/rocmlir" '
            '"${CMAKE_INSTALL_PREFIX}/include/rocmlir/external/include")\n'
            'set_target_properties(fixture PROPERTIES OUTPUT_NAME rockCompiler '
            'ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_INSTALL_PREFIX}/lib")\n'
            "add_library(rockCompiler INTERFACE)\n"
            'target_link_libraries(rockCompiler INTERFACE "$<INSTALL_INTERFACE:$<INSTALL_PREFIX>/lib/librockCompiler.a>")\n'
            'target_include_directories(rockCompiler INTERFACE "$<INSTALL_INTERFACE:include/rocmlir>" '
            '"$<INSTALL_INTERFACE:include/rocmlir/external/include>")\n'
            "install(TARGETS rockCompiler EXPORT rocmlir-targets)\n"
            "install(EXPORT rocmlir-targets NAMESPACE rocMLIR:: DESTINATION lib/cmake/rocmlir)\n"
            "include(CMakePackageConfigHelpers)\n"
            'write_basic_package_version_file("${CMAKE_INSTALL_PREFIX}/lib/cmake/rocmlir/rocmlir-config-version.cmake" '
            "VERSION 2.0.0 COMPATIBILITY AnyNewerVersion)\n")
        build = cls.root / "fixture build"
        cls.checked(["cmake", "-S", str(source), "-B", str(build), "-DCMAKE_INSTALL_PREFIX=" + str(cls.prefix)])
        cls.checked(["cmake", "--build", str(build), "--parallel", "2"])
        cls.checked(["cmake", "--install", str(build)])

    @staticmethod
    def checked(argv: list[str]) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(argv, capture_output=True, text=True, check=False, timeout=45,
                                env=dict(os.environ, LC_ALL="C"))
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        return result

    @classmethod
    def configure(cls, prefix: Path, build: Path, api: str | None = None) -> list[str]:
        return ["cmake", "-S", str(LIB / "rocmlir-host-consumer"), "-B", str(build),
                "-DROCMLIR_PREFIX=" + str(prefix), "-DROCMLIR_REQUIRED_VERSION=" + cls.version,
                "-DROCMLIR_REQUIRED_API_VERSION=" + (api or cls.api_version),
                "-DrocMLIR_DIR=" + str(prefix / "lib/cmake/rocmlir")]

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="rocMLIR API case ")
        self.addCleanup(temporary.cleanup)
        self.case = Path(temporary.name)

    def test_real_compiled_program_observes_registration_namespace_and_pipeline(self) -> None:
        trace = self.case / "calls"
        result = subprocess.run([str(self.binary)], capture_output=True, text=True, check=False, timeout=10,
                                env=dict(os.environ, LC_ALL="C", ROCMLIR_FIXTURE_TRACE=str(trace)))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "ROCMLIR API: version=6 dialect=migraphx pipeline=migraphx-to-tosa\n")
        self.assertEqual(trace.read_text().splitlines(), TRACE)

    def test_runtime_invalid_context_dialect_namespace_and_pipeline_refuse(self) -> None:
        for fault in ["registry", "context", "dialect", "namespace", "null-name", "length", "manager", "pipeline"]:
            trace = self.case / (fault + " trace")
            result = subprocess.run([str(self.binary)], capture_output=True, text=True, check=False, timeout=10,
                                    env=dict(os.environ, LC_ALL="C", ROCMLIR_FIXTURE_FAULT=fault,
                                             ROCMLIR_FIXTURE_TRACE=str(trace)))
            self.assertEqual(result.returncode, 3, (fault, result.stdout, result.stderr))
            self.assertEqual(result.stdout, "")
            if fault == "registry":
                expected = TRACE[:1]
            elif fault == "context":
                expected = TRACE[:5]
            elif fault == "dialect":
                expected = TRACE[:7] + ["context-destroy"]
            elif fault in {"namespace", "null-name", "length"}:
                expected = TRACE[:8] + ["context-destroy"]
            elif fault == "manager":
                expected = TRACE[:9] + ["context-destroy"]
            else:
                expected = TRACE
            self.assertEqual(trace.read_text().splitlines(), expected, fault)

    def test_program_output_failure_remains_fatal(self) -> None:
        with Path("/dev/full").open("wb") as sink:
            result = subprocess.run([str(self.binary)], stdout=sink, stderr=subprocess.PIPE, check=False, timeout=10)
        self.assertEqual(result.returncode, 4, result.stderr)

    def test_inexact_package_missing_target_or_foreign_inputs_refuse(self) -> None:
        for fault in ["version", "target", "package", "archive", "headers"]:
            prefix = self.case / (fault + " prefix")
            shutil.copytree(self.prefix, prefix)
            config = prefix / "lib/cmake/rocmlir"
            file = config / "rocmlir-config.cmake"
            if fault == "version":
                (config / "rocmlir-config-version.cmake").write_text(
                    'set(PACKAGE_VERSION "2.1.0")\nset(PACKAGE_VERSION_COMPATIBLE TRUE)\nset(PACKAGE_VERSION_EXACT FALSE)\n')
            elif fault == "target":
                file.write_text("set(FIXTURE_FOUND TRUE)\n")
            elif fault == "package":
                file.unlink()
            elif fault == "archive":
                foreign = self.case / "foreign.a"
                shutil.copy2(prefix / "lib/librockCompiler.a", foreign)
                export = config / "rocmlir-targets.cmake"
                export.write_text(export.read_text().replace("${_IMPORT_PREFIX}/lib/librockCompiler.a", str(foreign)))
            else:
                foreign = self.case / "foreign include"
                shutil.copytree(prefix / "include/rocmlir", foreign)
                export = config / "rocmlir-targets.cmake"
                export.write_text(export.read_text().replace("${_IMPORT_PREFIX}/include/rocmlir;", str(foreign) + ";"))
            fallback = self.case / (fault + " fallback")
            shutil.copytree(self.prefix, fallback)
            marker = self.case / (fault + " unexpectedly loaded fallback")
            fallback_config = fallback / "lib/cmake/rocmlir/rocmlir-config.cmake"
            fallback_config.write_text(fallback_config.read_text() + 'file(WRITE "' + str(marker) + '" "loaded")\n')
            result = subprocess.run(self.configure(prefix, self.case / fault), capture_output=True, text=True,
                                    check=False, timeout=20, env=dict(os.environ, LC_ALL="C", CMAKE_PREFIX_PATH=str(fallback)))
            self.assertNotEqual(result.returncode, 0, (fault, result.stdout))
            self.assertNotIn("Parse error", result.stdout + result.stderr)
            self.assertFalse(marker.exists(), fault)

    def test_incompatible_header_api_fails_actual_compilation(self) -> None:
        build = self.case / "wrong API"
        self.checked(self.configure(self.prefix, build, api="5"))
        result = subprocess.run(["cmake", "--build", str(build), "--parallel", "2"],
                                capture_output=True, text=True, check=False, timeout=30)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("static assertion", (result.stdout + result.stderr).lower())


    def transport_cache(self, clang: Path, prefix: Path, fault: str) -> str:
        cache = (
            "CMAKE_CXX_COMPILER_LAUNCHER:STRING=/fixture-cache\nCMAKE_C_COMPILER_LAUNCHER:STRING=/fixture-cache\n"
            f"CMAKE_CXX_COMPILER:FILEPATH={clang}/bin/clang++\nCMAKE_CXX_STANDARD:STRING=17\n"
            f"rocMLIR_DIR:PATH={prefix}/lib/cmake/rocmlir\n"
        )
        if fault == "compiler":
            cache = cache.replace(str(clang) + "/bin/clang++", "/foreign/compiler")
        elif fault == "standard":
            cache = cache.replace("CMAKE_CXX_STANDARD:STRING=17", "CMAKE_CXX_STANDARD:STRING=20")
        elif fault == "prefix-cache":
            cache = cache.replace(str(prefix / "lib/cmake/rocmlir"), "/foreign/package")
        return cache

    def transport(self, fault: str = "") -> tuple[subprocess.CompletedProcess[str], Path]:
        label = re.sub(r"[^A-Za-z0-9_-]", "_", fault or "valid")
        prefix = self.case / ("prefix " + label)
        shutil.copytree(self.prefix, prefix)
        source = self.case / ("original " + label)
        shutil.copytree(self.original, source)
        work = self.case / ("work " + label)
        clang = self.case / ("clang " + label)
        (clang / "bin").mkdir(parents=True)
        ar = shutil.which("ar")
        if ar is None:
            raise AssertionError("Fixture archive inspector is required")
        (clang / "bin/llvm-ar").symlink_to(ar)
        cache = self.transport_cache(clang, prefix, fault)
        if fault == "header":
            (prefix / "include/rocmlir/mlir-c/RegisterRocMLIR.h").write_bytes(b"foreign header bytes")
        elif fault == "original":
            (source / "mlir/include/mlir-c/RegisterRocMLIR.h").unlink()
        elif fault == "notice":
            (prefix / "share/licenses/rocmlir/LICENSE").write_bytes(b"foreign notice")
        elif fault == "policy":
            (prefix / "share/licenses/rocmlir/SOURCE-NOTICE-SHA256SUMS").write_text("foreign policy")
        if fault.startswith("header:"):
            (prefix / fault.split(":", 1)[1]).write_bytes(b"foreign header bytes")
        text = (LIB / "verify-source-rocmlir.sh").read_text()
        body = text[text.index("clang_root='' gcc_root=''"):]
        callbacks = r"""
migraphx_prepare_native_work() {
  mkdir "$1"
  printf -v "$3" '%s' "$FIXTURE_CLANG"
  printf -v "$4" '%s' '/selected GCC'
}
append_cmake_cache_linker_args() {
  local -n cache_args="$1"
  cache_args+=('-DCMAKE_CXX_COMPILER_LAUNCHER=/fixture-cache' '-DCMAKE_C_COMPILER_LAUNCHER=/fixture-cache')
  CMAKE_COMPILER_CACHE_PIN=/fixture-cache
  [[ "$FAULT" != cache ]] || CMAKE_COMPILER_CACHE_PIN=/wrong-cache
}
cmake() {
  if [[ "$1" == --build ]]; then
    [[ "$FAULT" != build ]] || return 37
    cp "$FIXTURE_BINARY" "$work/build/rocmlir-host-consumer"
    if [[ "$FAULT" == output ]]; then
      printf '#!/usr/bin/env bash\nprintf "wrong API output\\n"\n' > "$work/build/rocmlir-host-consumer"
    fi
  else
    [[ "$FAULT" != configure ]] || return 37
    mkdir -p "$work/build"
    printf '%s' "$FAKE_CACHE" > "$work/build/CMakeCache.txt"
    printf '%s\0' "$@" > "$work/build/actual-argv.nul"
    printf '%s\n' "$SELECTED_LIBRARY" > "$work/build/imported-library.txt"
  fi
}
"""
        selected = prefix / "lib/librockCompiler.a"
        if fault == "import":
            selected = self.case / "foreign archive.a"
            shutil.copy2(prefix / "lib/librockCompiler.a", selected)
        env = dict(os.environ, LC_ALL="C", FAULT=fault, FAKE_CACHE=cache, FIXTURE_CLANG=str(clang),
                   FIXTURE_BINARY=str(self.binary), SELECTED_LIBRARY=str(selected),
                   work=str(work), rocmlir_prefix=str(prefix), original_source=str(source),
                   SCRIPT_DIR=str(self.scripts), MIGRAPHX_ROCMLIR_VERSION=self.version,
                   MIGRAPHX_ROCMLIR_DIALECT_API_VERSION=self.api_version)
        env.pop("ROCMLIR_FIXTURE_MUTATE_LIBRARY", None)
        env["ROCMLIR_FIXTURE_FAULT"] = "pipeline" if fault == "runtime" else ""
        if fault in {"late-library", "late-notice"}:
            relative = "lib/librockCompiler.a" if fault == "late-library" else "share/licenses/rocmlir/LICENSE"
            env["ROCMLIR_FIXTURE_MUTATE_LIBRARY"] = str(prefix / relative)
        if fault.startswith("late:"):
            scope, relative = fault.split(":", 2)[1:]
            env["ROCMLIR_FIXTURE_MUTATE_LIBRARY"] = str((prefix if scope == "prefix" else source) / relative)
        imports = [ROOT / "linux/scripts/01-core/cmake-cache-linker.sh", LIB / "source-common.sh", LIB / "source-rocmlir.sh"]
        prelude = "set -euo pipefail\n" + "".join("source " + shlex.quote(str(path)) + "\n" for path in imports)
        return subprocess.run(["bash", "-c", prelude + callbacks + body], capture_output=True, text=True,
                              check=False, timeout=15, env=env), work

    def test_shell_worker_preserves_exact_inputs_cache_flags_and_api_output(self) -> None:
        result, work = self.transport()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((work / "inputs-before.sha256").read_bytes(), (work / "inputs-after.sha256").read_bytes())
        self.assertEqual((work / "api-output.txt").read_text(),
                         "ROCMLIR API: version=6 dialect=migraphx pipeline=migraphx-to-tosa\n")
        args = (work / "build/actual-argv.nul").read_bytes().split(b"\0")
        for value in ["-DCMAKE_CXX_STANDARD=17", "-DROCMLIR_REQUIRED_API_VERSION=6",
                      "-DCMAKE_CXX_COMPILER_LAUNCHER=/fixture-cache",
                      "-DCMAKE_CXX_COMPILER_EXTERNAL_TOOLCHAIN=/selected GCC"]:
            self.assertIn(value.encode(), args)
        self.assertIn("ROCMLIR EXTERNAL CONSUMER PASSED:", result.stdout)

    def test_shell_worker_refuses_raw_failures_input_drift_and_invalid_api(self) -> None:
        for fault, status in [
            ("configure", 37), ("build", 37), ("cache", 1), ("compiler", 1),
            ("standard", 1), ("prefix-cache", 1), ("import", 1), ("runtime", 3), ("output", 1),
            ("header", 1), ("original", 2), ("notice", 1), ("policy", 1),
            ("late-library", 1), ("late-notice", 1),
        ]:
            with self.subTest(fault=fault):
                result, _work = self.transport(fault)
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                self.assertNotIn("ROCMLIR EXTERNAL CONSUMER PASSED:", result.stdout)
                if fault in {"header", "original", "notice", "policy"}:
                    self.assertFalse((_work / "build/actual-argv.nul").exists(), fault)

    def test_real_worker_cli_refuses_bad_arity_before_bootstrap(self) -> None:
        for args in [[], ["work"], ["work", "prefix"], ["work", "prefix", "source", "extra"]]:
            result = subprocess.run(["bash", str(LIB / "verify-source-rocmlir.sh"), *args],
                                    capture_output=True, text=True, check=False, timeout=10)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)


    def test_every_selected_original_header_is_compared_before_configuration(self) -> None:
        for relative in [
            "include/rocmlir/mlir-c/RegisterRocMLIR.h",
            "include/rocmlir/mlir-c/Dialect/MIGraphX.h",
            "include/rocmlir/external/include/mlir-c/IR.h",
        ]:
            result, work = self.transport("header:" + relative)
            self.assertEqual(result.returncode, 1, (relative, result.stdout, result.stderr))
            self.assertFalse((work / "build/actual-argv.nul").exists())

    def test_every_selected_installed_or_original_input_is_stable_after_api(self) -> None:
        for scope, relative in [
            ("prefix", "lib/librockCompiler.a"),
            ("prefix", "lib/cmake/rocmlir/rocmlir-config.cmake"),
            ("prefix", "lib/cmake/rocmlir/rocmlir-config-version.cmake"),
            ("prefix", "lib/cmake/rocmlir/rocmlir-targets.cmake"),
            ("prefix", "include/rocmlir/mlir-c/RegisterRocMLIR.h"),
            ("prefix", "include/rocmlir/mlir-c/Dialect/MIGraphX.h"),
            ("prefix", "include/rocmlir/external/include/mlir-c/IR.h"),
            ("original", "mlir/include/mlir-c/RegisterRocMLIR.h"),
            ("original", "mlir/include/mlir-c/Dialect/MIGraphX.h"),
            ("original", "external/llvm-project/mlir/include/mlir-c/IR.h"),
        ]:
            result, work = self.transport("late:" + scope + ":" + relative)
            self.assertEqual(result.returncode, 1, (scope, relative, result.stdout, result.stderr))
            self.assertTrue((work / "api-output.txt").is_file())
            self.assertNotIn("ROCMLIR EXTERNAL CONSUMER PASSED:", result.stdout)


if __name__ == "__main__":
    unittest.main()
