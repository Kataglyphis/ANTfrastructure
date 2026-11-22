"""A host C compiler and fake API test CMake ownership; they do not build Emscripten or real ORT."""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

TESTS = Path(__file__).resolve().parent
HOOK = TESTS.parent / "03-media/build/onnxruntime/build/lib/webgpu-factory-probe/wasm.cmake"


class WasmHookTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.project = self.root / "repo with spaces/cmake"
        self.project.mkdir(parents=True)
        self.headers = self.project.parent / "include/onnxruntime/core/session"
        self.headers.mkdir(parents=True)
        shutil.copy2(TESTS / "fixtures/webgpu-native/onnxruntime_c_api.h", self.headers)
        self.build = self.root / "build with spaces"
        self.operator = self.root / "operator include.cmake"
        self.operator.write_text('set(OPERATOR_INCLUDE_RAN TRUE CACHE BOOL "" FORCE)\n')
        self.write_project()

    def write_project(self, target: bool = True) -> None:
        body = ['cmake_minimum_required(VERSION 3.25)', 'project(fixture LANGUAGES C)']
        if target:
            source = TESTS / "fixtures/webgpu-native"
            body += [f'add_executable(onnxruntime_webassembly "{source}/core.c" "{source}/linked-main.c")',
                     f'target_include_directories(onnxruntime_webassembly PRIVATE "{self.headers}")']
        body += ['add_subdirectory(nested)', 'cmake_language(DEFER CALL write_sources)',
                 'function(write_sources)',
                 '  if(TARGET onnxruntime_webassembly)',
                 '    get_target_property(sources onnxruntime_webassembly SOURCES)',
                 '    file(WRITE "${CMAKE_BINARY_DIR}/sources.txt" "${sources}")',
                 '    file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/target.txt" CONTENT "$<TARGET_FILE:onnxruntime_webassembly>")',
                 '  endif()', 'endfunction()']
        (self.project / "CMakeLists.txt").write_text("\n".join(body) + "\n")
        nested = self.project / "nested"
        nested.mkdir(exist_ok=True)
        (nested / "CMakeLists.txt").write_text("project(nested_fixture LANGUAGES C)\n")

    def configure(self, *extra: str) -> subprocess.CompletedProcess[str]:
        command = ["cmake", "-S", str(self.project), "-B", str(self.build),
                   f"-DCMAKE_PROJECT_TOP_LEVEL_INCLUDES={self.operator};{HOOK}",
                   "-DCMAKE_SYSTEM_NAME=Emscripten", "-Donnxruntime_USE_WEBGPU=ON",
                   "-Donnxruntime_USE_EP_API_ADAPTERS=ON", "-Donnxruntime_WEBGPU_STATIC_PLUGIN=ON",
                   "-Donnxruntime_USE_EXTERNAL_DAWN=OFF",
                   "-DCMAKE_C_FLAGS=-DWEBGPU_COMPILER_FIXTURE=37 -DWEBGPU_SECOND_FLAG=41", *extra]
        return subprocess.run(command, capture_output=True, text=True, check=False, timeout=30)

    def test_deferred_hook_preserves_operator_and_nested_projects_and_builds_the_same_c_source(self) -> None:
        result = self.configure()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        cache = (self.build / "CMakeCache.txt").read_text()
        self.assertIn("OPERATOR_INCLUDE_RAN:BOOL=TRUE", cache)
        self.assertEqual((self.build / "sources.txt").read_text().count(str(HOOK.with_name("probe.c"))), 1)
        result = subprocess.run(["cmake", "--build", str(self.build)], capture_output=True,
                                text=True, check=False, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        trace = self.root / "trace"
        result = subprocess.run([(self.build / "target.txt").read_text(), "ON"], capture_output=True,
                                text=True, check=False, timeout=10,
                                env={**os.environ, "WEBGPU_NATIVE_LOG": str(trace), "WEBGPU_NATIVE_SCENARIO": "static"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("WEBGPU-WASM OK: mode=ON api=31", result.stdout)
        self.assertEqual(trace.read_text().splitlines()[-1], "RELEASEENV")

    def test_repeated_operator_hook_cannot_attach_the_probe_twice(self) -> None:
        result = self.configure(f"-DCMAKE_PROJECT_TOP_LEVEL_INCLUDES={self.operator};{HOOK};{HOOK}")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.build / "sources.txt").read_text().count(str(HOOK.with_name("probe.c"))), 1)

    def test_missing_target_or_header_fails_before_any_build(self) -> None:
        self.write_project(target=False)
        result = self.configure()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("owning ORT WebAssembly target is required", result.stderr)
        shutil.rmtree(self.build)
        self.write_project()
        (self.headers / "onnxruntime_c_api.h").unlink()
        result = self.configure()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("owning WASM C API header is required", result.stderr)

    def test_wrong_target_system_or_any_legacy_provider_flag_refuses(self) -> None:
        for definition in ("CMAKE_SYSTEM_NAME=Linux", "onnxruntime_USE_WEBGPU=OFF",
                           "onnxruntime_USE_EP_API_ADAPTERS=OFF", "onnxruntime_WEBGPU_STATIC_PLUGIN=OFF",
                           "onnxruntime_USE_EXTERNAL_DAWN=ON"):
            with self.subTest(definition=definition):
                if self.build.exists():
                    shutil.rmtree(self.build)
                result = self.configure("-D" + definition)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("integrated-Dawn static plugin", result.stderr)
