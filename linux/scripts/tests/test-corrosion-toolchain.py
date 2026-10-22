#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Exercise generated Rust bridge flags without compiling or downloading a crate."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


MODULE = Path(__file__).resolve().parents[3] / "cmake" / "CorrosionToolchain.cmake"


class CorrosionToolchainTests(unittest.TestCase):
    def configure(self, windows=False, asan=False, config="Debug"):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "CMakeLists.txt").write_text(
                "cmake_minimum_required(VERSION 3.20)\nproject(bridge NONE)\n"
                "add_library(bridge INTERFACE)\n"
                f"set(WIN32 {'TRUE' if windows else 'FALSE'})\n"
                "set(MSVC TRUE)\nset(CMAKE_CXX_COMPILER_ID Clang)\n"
                "set(CMAKE_C_COMPILER /toolchain/clang)\n"
                "set(CMAKE_CXX_COMPILER /toolchain/clang++)\n"
                "function(corrosion_set_env_vars target)\n"
                "  set_property(GLOBAL PROPERTY bridge_env \"${ARGN}\")\nendfunction()\n"
                f'include("{MODULE.as_posix()}")\n'
                f"kataglyphis_configure_corrosion_target(bridge ADDRESS_SANITIZER {'ON' if asan else 'OFF'})\n"
                "get_property(flags GLOBAL PROPERTY bridge_env)\n"
                'file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/flags.txt" CONTENT "${flags}")\n',
                encoding="utf-8",
            )
            env = dict(os.environ, CXXFLAGS="-march=native")
            subprocess.run(
                ["cmake", "-S", str(root), "-B", str(root / "build"), "-G", "Ninja", f"-DCMAKE_BUILD_TYPE={config}"],
                check=True, capture_output=True, text=True, env=env,
            )
            return (root / "build/flags.txt").read_text(encoding="utf-8")

    def test_native_preserves_configured_compilers_and_flags(self):
        flags = self.configure()
        self.assertIn("CC=/toolchain/clang", flags)
        self.assertIn("CXX=/toolchain/clang++", flags)
        self.assertIn("CXXFLAGS=-march=native -fexceptions", flags)

    def test_windows_debug_uses_matching_debug_crt(self):
        flags = self.configure(windows=True)
        self.assertIn("CFLAGS=/MDd /D_DEBUG", flags)
        self.assertIn("/D_ITERATOR_DEBUG_LEVEL=2", flags)

    def test_asan_debug_uses_release_crt_and_iterator_abi(self):
        flags = self.configure(windows=True, asan=True)
        self.assertNotIn("/MDd", flags)
        self.assertNotIn("/D_DEBUG", flags)
        self.assertIn("CFLAGS=/MD", flags)
        self.assertIn("/D_ITERATOR_DEBUG_LEVEL=0", flags)

    def test_profile_uses_release_crt(self):
        flags = self.configure(windows=True, config="RelWithDebInfo")
        self.assertNotIn("/MDd", flags)
        self.assertIn("/MD /DNDEBUG", flags)


if __name__ == "__main__":
    unittest.main()
