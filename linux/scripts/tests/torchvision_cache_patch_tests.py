#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Test patched launcher selection and drift; not real compilation or a wheel build."""
import json
import runpy
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path

REPO = Path(sys.argv.pop(1)).resolve()
PATCH = REPO / 'windows/scripts/patches/pytorch/001-torchvision-host-sccache.patch'
FIXTURE = 'def configuration():\n    compiler = get_cxx_compiler()\n\n    # Version 1.3 is required for the `deps` directive.\n    config = [\'ninja_required_version = 1.3\']\n    config.append(f\'cxx = {_shell_join(_wrap_compiler(compiler))}\')\n    if with_cuda or cuda_dlink_post_cflags:\n        if "PYTORCH_NVCC" in os.environ:\n            nvcc = os.getenv("PYTORCH_NVCC")    # user can set nvcc compiler with ccache using the environment variable here\n    return config, locals().get(\'nvcc\')\n'
COMPILER = 'C:/SDK with spaces/clang-cl.exe'
LAUNCHER = 'C:/Cache with spaces/sccache.exe'


class LauncherTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        temporary = tempfile.TemporaryDirectory(prefix='torchvision-cache-patch-')
        cls.addClassCleanup(temporary.cleanup)
        cls.root = Path(temporary.name)
        subprocess.run(['git', 'init', '-q', str(cls.root)], check=True, capture_output=True)
        cls.source = cls.root / 'torch/utils/cpp_extension.py'
        cls.source.parent.mkdir(parents=True)
        cls.source.write_bytes(FIXTURE.encode('utf-8'))
        subprocess.run(['git', '-C', str(cls.root), 'apply', '--check', str(PATCH)], check=True, capture_output=True)
        subprocess.run(['git', '-C', str(cls.root), 'apply', str(PATCH)], check=True, capture_output=True)

    def selection(self, windows: bool, hip: bool, launcher: str | None, cuda: bool = False) -> tuple[list[str], str | None]:
        environ = {'PYTORCH_NVCC': 'unaltered hip compiler'}
        if launcher:
            environ['TORCHVISION_CXX_COMPILER_LAUNCHER'] = launcher
        scope = runpy.run_path(str(self.source), init_globals={
            'IS_WINDOWS': windows, 'IS_HIP_EXTENSION': hip, 'with_cuda': cuda,
            'cuda_dlink_post_cflags': [], 'get_cxx_compiler': lambda: COMPILER,
            '_wrap_compiler': lambda compiler: [compiler], '_shell_join': json.dumps,
            'os': types.SimpleNamespace(environ=environ, getenv=environ.get),
        })
        config, nvcc = scope['configuration']()
        return json.loads(config[1].removeprefix('cxx = ')), nvcc

    def test_explicit_windows_hip_host_launcher_has_two_preserved_arguments(self) -> None:
        self.assertEqual(self.selection(True, True, LAUNCHER)[0], [LAUNCHER, COMPILER])

    def test_missing_launcher_preserves_default(self) -> None:
        self.assertEqual(self.selection(True, True, None)[0], [COMPILER])

    def test_other_platform_routes_preserve_default(self) -> None:
        for windows, hip in [(False, True), (True, False), (False, False)]:
            with self.subTest(windows=windows, hip=hip):
                self.assertEqual(self.selection(windows, hip, LAUNCHER)[0], [COMPILER])

    def test_hip_compiler_is_separate_from_host_launcher(self) -> None:
        host, device = self.selection(True, True, LAUNCHER, cuda=True)
        self.assertEqual(host, [LAUNCHER, COMPILER])
        self.assertEqual(device, 'unaltered hip compiler')

    def test_applied_patch_has_a_clean_reverse_for_idempotent_owner(self) -> None:
        result = subprocess.run(['git', '-C', str(self.root), 'apply', '--reverse', '--check', str(PATCH)], check=False, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_upstream_drift_refuses(self) -> None:
        with tempfile.TemporaryDirectory(dir=self.root) as work:
            destination = Path(work) / 'torch/utils/cpp_extension.py'
            destination.parent.mkdir(parents=True)
            destination.write_bytes(FIXTURE.replace("config.append(f'cxx = {_shell_join(_wrap_compiler(compiler))}')", 'config.append("upstream changed")').encode('utf-8'))
            subprocess.run(['git', 'init', '-q', work], check=True, capture_output=True)
            result = subprocess.run(['git', '-C', work, 'apply', '--check', str(PATCH)], check=False, capture_output=True)
            self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
