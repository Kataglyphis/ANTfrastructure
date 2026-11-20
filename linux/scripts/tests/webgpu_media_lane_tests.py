#!/usr/bin/env python3
"""Check all six command profiles against independent expectations and the real shell graph; no image or device proof."""

from __future__ import annotations

import importlib
import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'linux/scripts/local-proof'))
MEDIA = importlib.import_module('webgpu_media_lanes')


class MediaLaneTests(unittest.TestCase):
    def inputs(self, variant: str = 'default', arch: str = 'amd64', parent: str = 'sdk',
               repo: str = 'ant-local/webgpu-fixture', reference: str = '', context: Path = Path('/parent context')) -> dict:
        return MEDIA.media_inputs(ROOT, Path('/proof space'), repo, variant, arch, parent, context,
                                  reference or 'ant-local/webgpu-parent@sha256:' + 'a' * 64)

    def test_exact_six_lanes_and_canonical_commands(self) -> None:
        cases = [('default', 'amd64', 'sdk', 'cross-media-amd64'),
                 ('default', 'arm64', 'sdk', 'cross-media-arm64'),
                 ('default', 'riscv64', 'sdk', 'cross-media-riscv64'),
                 ('rocm', 'amd64', 'gpu', 'cross-media-rocm-amd64'),
                 ('nvidia', 'amd64', 'gpu', 'cross-media-nvidia-amd64'),
                 ('nvidia', 'arm64', 'gpu', 'cross-media-nvidia-arm64')]
        self.assertEqual(MEDIA.LANES, tuple((variant, arch) for variant, arch, _, _ in cases))
        for variant, arch, parent, tag in cases:
            with self.subTest(variant=variant, arch=arch):
                record = self.inputs(variant, arch, parent)
                suffix = '-stages' if variant == 'nvidia' else ''
                self.assertEqual(record['image'], 'ant-local/webgpu-fixture' + suffix + ':' + tag)
                self.assertEqual(record['driver'], ['/bin/bash', str(ROOT / 'linux/scripts/build-cross-stage.sh'),
                                                   '--stage', 'media', '--arch', arch, '--image-repo',
                                                   'ant-local/webgpu-fixture', '--log-dir', '/proof space/logs'])
                expected = ['CROSS_MEDIA_BASE_IMAGE=ant-local/webgpu-parent@sha256:' + 'a' * 64,
                            'CROSS_MEDIA_BASE_CONTEXT=/parent context']
                if variant != 'default':
                    expected += ['CROSS_VARIANT=' + variant]
                expected += ['ORT_WEB_REQUIRED=1', 'ORT_WASM_WEBGPU_FLAVORS=true', 'CROSS_BUILD_PLATFORM=linux/amd64']
                expected += ['ORT_ENABLE_WEBGPU=true', 'ORT_WEBGPU_ALLOW_CROSS=true']
                expected += ['ENABLE_AMD=' + ('true' if variant == 'rocm' else 'false'),
                             'ENABLE_NVIDIA=' + ('true' if variant == 'nvidia' else 'false')]
                if variant == 'default':
                    expected += ['CROSS_VARIANT=']
                if (variant, arch) == ('nvidia', 'arm64'):
                    expected += ['CROSS_NVIDIA_SBSA=1']
                self.assertEqual(record['environment'], expected)
                self.assertEqual((record['variant'], record['target_arch'], record['parent_stage']), (variant, arch, parent))
                self.assertFalse(record['publication'])
                self.assertFalse(record['parent_ancestry_verified'])
                self.assertFalse(record['launched'])
                self.check_shell_graph(record)

    def test_ambient_accelerators_cannot_change_selected_tag(self) -> None:
        for values in [{'ENABLE_AMD':'true', 'ENABLE_NVIDIA':'false'},
                       {'ENABLE_AMD':'false', 'ENABLE_NVIDIA':'true'},
                       {'ENABLE_AMD':'true', 'ENABLE_NVIDIA':'true'}]:
            with self.subTest(values=values), mock.patch.dict(os.environ, values):
                self.assertEqual(self.inputs()['image'], 'ant-local/webgpu-fixture:cross-media-amd64')
                self.assertEqual(self.inputs('rocm', 'amd64', 'gpu')['image'], 'ant-local/webgpu-fixture:cross-media-rocm-amd64')

    def check_shell_graph(self, record: dict) -> None:
        command = ['env', '-i', 'PATH=/usr/local/bin:/usr/bin:/bin', *record['environment'], 'bash', '-euo', 'pipefail', '-c',
                   ('source "$1/platform.sh"; source "$1/build-helpers.sh"; source "$1/tag-naming.sh"; '
                   'source "$1/stage-defs.sh"; source "$1/version-forwarding.sh"; IMAGE_REPO="$2"; '
                   'test -z "$(cross_variant_refusal media "$3" media)"; '
                   'printf "%s\\n" "$(cross_stage_parent media)" "$(cross_stage_tag media "$3")"; '
                   'args=(); cross_stage_build_args args media "$3"; append_version_build_args args "$3"; '
                   'printf "%s\\n" "${args[@]}"'),
                   'media-lane-graph', str(ROOT / 'linux/scripts/01-core'), 'ant-local/webgpu-fixture', record['target_arch']]
        result = subprocess.run(command, capture_output=True, text=True, timeout=30, check=True)
        lines = result.stdout.splitlines()
        self.assertEqual(lines[:2], [record['parent_stage'], record['image']])
        self.assertIn('TARGET_ARCH=' + record['target_arch'], lines)
        self.assertIn('ORT_WEB_REQUIRED=1', lines)
        self.assertIn('ORT_WASM_WEBGPU_FLAVORS=true', lines)
        self.assertIn('ORT_ENABLE_WEBGPU=true', lines)
        self.assertIn('ORT_WEBGPU_ALLOW_CROSS=true', lines)
        if record['variant'] == 'nvidia':
            self.assertIn('ENABLE_NVIDIA=true', lines)
        if record['variant'] == 'rocm':
            self.assertIn('ENABLE_AMD=true', lines)

    def test_foreign_lane_and_wrong_parent_refuse(self) -> None:
        for variant, arch, parent in [('default', 'ppc64le', 'sdk'), ('rocm', 'arm64', 'gpu'),
                                     ('nvidia', 'riscv64', 'gpu'), ('cuda', 'amd64', 'gpu'),
                                     ('default', 'amd64', 'gpu'), ('nvidia', 'amd64', 'sdk')]:
            with self.subTest(variant=variant, arch=arch, parent=parent), self.assertRaises(AssertionError):
                self.inputs(variant, arch, parent)

    def test_parent_must_be_immutable_and_local_output_explicit(self) -> None:
        for value in ['ant-local/webgpu-parent:latest', 'ant-local/webgpu-parent@sha256:' + 'A' * 64,
                      'ant-local/webgpu-parent@sha256:' + 'a' * 63, 'registry.invalid/parent@sha256:' + 'a' * 64]:
            with self.subTest(reference=value), self.assertRaises(AssertionError):
                self.inputs(reference=value)
        for value in ['public/image', 'ant-local/webgpu-fixture:latest', 'ant-local/webgpu-../bad\n']:
            with self.subTest(repo=value), self.assertRaises(AssertionError):
                self.inputs(repo=value)
        with self.assertRaises(AssertionError):
            self.inputs(context=Path('relative'))


if __name__ == '__main__':
    unittest.main()
