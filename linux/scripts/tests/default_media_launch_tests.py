#!/usr/bin/env python3
"""Check real command selection with synthetic SDK/source receipts; no engine, OCI provenance, factory or hardware proof."""

from __future__ import annotations

import copy
import importlib
import json
import os
import subprocess
import sys
import unittest
from typing import TYPE_CHECKING
from unittest import mock

import normal_stage_tests as fixtures

if TYPE_CHECKING:
    from proof_types import Json

MODULE = importlib.import_module('default_media_launch')


class DefaultMediaTests(unittest.TestCase):
    def setUp(self) -> None:
        fixture = fixtures.StageTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        self.work = fixture.work
        self.full = self.work / 'full.json'
        self.full.write_text('synthetic exact source proof')
        self.plan = {'source': str(self.work), 'source_revision': 'f' * 40,
                     'full_source_preflight_proof': str(self.full), 'required_bytes': 180 * 1024**3}
        self.plan_path = self.work / 'plan.json'
        self.plan_path.write_text(json.dumps(self.plan))
        self.sdk_path = self.work / 'SDK-invocation.json'
        self.sdk = {'target_arch': 'amd64', 'source': str(self.work), 'source_revision': 'f' * 40,
                    'SDK_source_full_preflight_proof': str(self.full),
                    'image': 'ant-local/webgpu-sdk:cross-sdk-amd64'}
        self.parent: Json = {'manifest': 'sha256:' + 'a' * 64, 'config': 'sha256:' + 'b' * 64,
                       'index_sha256': 'c' * 64, 'layers': 29,
                       'matched_compiler_layers_and_diffIDs': 26,
                       'subject': {'source_proof_sha256': fixtures.sha(self.full)}}
        self.save_sdk()
        self.proof_path = self.work / 'SDK-proof.json'
        self.proof_path.write_text(json.dumps(self.parent))
        self.context = self.work / 'SDK context'
        self.output = self.work / 'output space'
        self.unit = 'webgpu-normal-media-default-amd64-99999999-1.service'
        self.repo = 'ant-local/webgpu-default-fixture'

    def save_sdk(self) -> None:
        self.sdk_path.write_text(json.dumps(self.sdk))
        self.parent['subject']['sdk_invocation_sha256'] = fixtures.sha(self.sdk_path)

    def load(self, parent: dict | None = None, *, arch: str = 'amd64') -> tuple:
        loader = mock.Mock(return_value=(parent or self.parent, self.context))
        with mock.patch.object(MODULE, 'full_source') as full, \
                mock.patch.object(MODULE.runpy, 'run_path', return_value={'sdk_parent': loader}) as api:
            result = MODULE.sdk_media_parent(self.plan_path, self.sdk_path, self.proof_path, arch=arch)
        full.assert_called_once_with(self.work, self.full, self.plan['source_revision'])
        api.assert_called_once_with(str(fixtures.TOOLS / 'launch-normal-gpu.py'))
        loader.assert_called_once_with(self.plan, self.sdk_path, self.proof_path, arch=arch)
        return result

    def test_qualified_sdk_inputs_are_retained(self) -> None:
        plan, sdk, parent, context = self.load()
        self.assertEqual((plan, parent, context), (self.plan, self.parent, self.context))
        self.assertEqual(sdk['source_full_preflight_proof'], str(self.full))
        self.assertEqual(sdk['source_full_preflight_sha256'], fixtures.sha(self.full))
        self.assertEqual(sdk['SDK_source_full_preflight_proof'], str(self.full))

    def test_wrong_architecture_or_source_refuses(self) -> None:
        for field, value, message in [('target_arch', 'arm64', 'reviewed amd64 SDK'),
                                      ('source', str(self.work / 'different'), 'exact SDK source'),
                                      ('source_revision', 'e' * 40, 'exact SDK source')]:
            original = self.sdk[field]
            self.sdk[field] = value
            self.save_sdk()
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, message):
                self.load()
            self.sdk[field] = original
            self.save_sdk()

    def test_missing_sdk_parent_api_refuses(self) -> None:
        for api in ({}, {'sdk_parent': 0}):
            with self.subTest(api=api), mock.patch.object(MODULE, 'full_source'), \
                    mock.patch.object(MODULE.runpy, 'run_path', return_value=api), \
                    self.assertRaisesRegex(ValueError, 'parent API is missing'):
                MODULE.sdk_media_parent(self.plan_path, self.sdk_path, self.proof_path)

    def test_changed_invocation_and_source_receipt_refuse(self) -> None:
        for key, message in [('sdk_invocation_sha256', 'SDK invocation changed'),
                             ('source_proof_sha256', 'SDK source proof changed')]:
            parent = copy.deepcopy(self.parent)
            parent['subject'][key] = '0' * 64
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, message):
                self.load(parent)

    def test_source_or_sdk_failure_propagates_before_launch(self) -> None:
        with mock.patch.object(MODULE, 'full_source', side_effect=RuntimeError('failed source')), \
                mock.patch.object(MODULE.runpy, 'run_path') as api, \
                self.assertRaisesRegex(RuntimeError, 'failed source'):
            MODULE.sdk_media_parent(self.plan_path, self.sdk_path, self.proof_path)
        api.assert_not_called()
        failure = subprocess.CalledProcessError(47, ['SDK parent'])
        with mock.patch.object(MODULE, 'full_source'), \
                mock.patch.object(MODULE.runpy, 'run_path', return_value={'sdk_parent': mock.Mock(side_effect=failure)}), \
                self.assertRaises(subprocess.CalledProcessError) as caught:
            MODULE.sdk_media_parent(self.plan_path, self.sdk_path, self.proof_path)
        self.assertEqual(caught.exception.returncode, 47)

    def test_default_command_and_record_keep_all_required_flags(self) -> None:
        selected = self.load()
        with mock.patch.object(MODULE, 'sdk_media_parent', return_value=selected) as parent, \
                mock.patch.object(MODULE, 'launch_build', return_value=47) as build, \
                mock.patch.dict(os.environ, {'ENABLE_AMD': 'true', 'ENABLE_NVIDIA': 'true'}):
            result = MODULE.launch(self.plan_path, self.sdk_path, self.proof_path, self.output, self.unit, self.repo)
        self.assertEqual(result, 47)
        parent.assert_called_once_with(self.plan_path, self.sdk_path, self.proof_path, arch='amd64')
        source, output, unit, image, arch, required, record, environment, driver = build.call_args.args
        self.assertEqual((source, output, unit, image, arch),
                         (self.work, self.output, self.unit, self.repo + ':cross-media-amd64', 'amd64'))
        self.assertEqual(required, 300 * 1024**3)
        self.assertEqual(environment, ['CROSS_MEDIA_BASE_IMAGE=ant-local/webgpu-sdk@' + self.parent['manifest'],
                                      'CROSS_MEDIA_BASE_CONTEXT=' + str(self.context),
                                      'ORT_WEB_REQUIRED=1', 'ORT_WASM_WEBGPU_FLAVORS=true',
                                      'CROSS_BUILD_PLATFORM=linux/amd64', 'ORT_ENABLE_WEBGPU=true',
                                      'ORT_WEBGPU_ALLOW_CROSS=true', 'ENABLE_AMD=false',
                                      'ENABLE_NVIDIA=false', 'CROSS_VARIANT='])
        self.assertEqual(driver, ['/bin/bash', str(self.work / 'linux/scripts/build-cross-stage.sh'),
                                  '--stage', 'media', '--arch', 'amd64', '--image-repo', self.repo,
                                  '--log-dir', str(self.output / 'logs')])
        self.assertEqual((record['stage'], record['variant'], record['parent_kind']), ('media', 'default', 'SDK'))
        self.assertEqual(record['SDK_invocation'], str(self.sdk_path))
        self.assertEqual(record['SDK_invocation_sha256'], fixtures.sha(self.sdk_path))
        self.assertEqual(record['source_full_preflight_sha256'], fixtures.sha(self.full))
        self.assertEqual(record['parent_OCI_proof'], str(self.proof_path))
        self.assertEqual(record['parent_OCI_proof_sha256'], fixtures.sha(self.proof_path))
        self.assertEqual(record['SDK_layers_rehashed'], 29)
        self.assertEqual(record['compiler_layers_matched'], 26)
        self.assertEqual((record['ORT_WEB_REQUIRED'], record['ORT_WASM_WEBGPU_FLAVORS']), (1, True))
        self.assertFalse(record['GPU_or_FINAL_acceptance'])
        self.assertEqual(set(record['launcher_inputs_sha256']), {'launch-default-amd64-media.py',
                         'default_media_launch.py', 'normal_stage_launch.py', 'webgpu_media_lanes.py', 'launch-normal-gpu.py'})
        for name, digest in record['launcher_inputs_sha256'].items():
            self.assertEqual(digest, fixtures.sha(fixtures.TOOLS / name))

    def test_a_stricter_caller_reserve_is_retained(self) -> None:
        selected = self.load()
        selected[0]['required_bytes'] = 400 * 1024**3
        with mock.patch.object(MODULE, 'sdk_media_parent', return_value=selected), \
                mock.patch.object(MODULE, 'launch_build', return_value=0) as build:
            MODULE.launch(self.plan_path, self.sdk_path, self.proof_path, self.output, self.unit, self.repo)
        self.assertEqual(build.call_args.args[5], 400 * 1024**3)

    def test_unreviewed_unit_refuses_before_reading_parent(self) -> None:
        for unit in ['webgpu-normal-media-amd64-99999999-1.service', 'other.service', self.unit + '\n']:
            with self.subTest(unit=unit), mock.patch.object(MODULE, 'sdk_media_parent') as parent, \
                    self.assertRaisesRegex(ValueError, 'Explicit default amd64'):
                MODULE.launch(self.plan_path, self.sdk_path, self.proof_path, self.output, unit, self.repo)
            parent.assert_not_called()

    def test_help_is_readonly_and_parser_forwards_exact_arguments(self) -> None:
        with mock.patch.object(sys, 'argv', ['launch-default-amd64-media.py', '--help']), \
                mock.patch.object(MODULE, 'launch') as launch, self.assertRaises(SystemExit) as caught:
            MODULE.main()
        self.assertEqual(caught.exception.code, 0)
        launch.assert_not_called()
        argv = ['launch-default-amd64-media.py', '--compiler-plan', str(self.plan_path),
                '--sdk-invocation', str(self.sdk_path), '--parent-proof', str(self.proof_path),
                '--output', str(self.output), '--unit', self.unit, '--image-repo', self.repo]
        with mock.patch.object(sys, 'argv', argv), mock.patch.object(MODULE, 'launch', return_value=53) as launch:
            self.assertEqual(MODULE.main(), 53)
        launch.assert_called_once_with(self.plan_path, self.sdk_path, self.proof_path, self.output, self.unit, self.repo, arch='amd64')

    def test_foreign_default_lanes_require_matching_qualified_sdk_target(self) -> None:
        for arch in ('arm64', 'riscv64'):
            self.sdk.update(target_arch=arch, image='ant-local/webgpu-sdk:cross-sdk-' + arch)
            self.save_sdk()
            unit = f'webgpu-normal-media-default-{arch}-99999999-1.service'
            selected = self.load(arch=arch)
            with self.subTest(arch=arch), mock.patch.object(MODULE, 'sdk_media_parent', return_value=selected) as parent, \
                    mock.patch.object(MODULE, 'launch_build', return_value=47) as build:
                self.assertEqual(MODULE.launch(self.plan_path, self.sdk_path, self.proof_path,
                                               self.output, unit, self.repo, arch=arch), 47)
                parent.assert_called_once_with(self.plan_path, self.sdk_path, self.proof_path, arch=arch)
                args = build.call_args.args
                self.assertEqual(args[3:6], (self.repo + ':cross-media-' + arch, arch, 300 * 1024**3))
                self.assertIn('CROSS_BUILD_PLATFORM=linux/amd64', args[7])
                self.assertIn('ORT_WASM_WEBGPU_FLAVORS=true', args[7])
                self.assertEqual(args[8][4:6], ['--arch', arch])
            with self.assertRaisesRegex(ValueError, 'reviewed amd64 SDK'):
                self.load()
            with mock.patch.object(MODULE, 'sdk_media_parent') as parent, self.assertRaisesRegex(ValueError, 'Explicit default'):
                MODULE.launch(self.plan_path, self.sdk_path, self.proof_path, self.output, self.unit, self.repo, arch=arch)
            parent.assert_not_called()

    def test_optimized_python_cannot_remove_shared_parent_guards(self) -> None:
        code = ('from pathlib import Path; import default_media_launch as module; '
                'module.sdk_media_parent(Path("absent"), Path("absent"), Path("absent"))')
        result = subprocess.run([sys.executable, '-O', '-c', code], cwd=self.work,
                                env={**os.environ, 'PYTHONPATH': str(fixtures.TOOLS)},
                                capture_output=True, text=True, timeout=20, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Optimization disables shared parent safety assertions', result.stderr)


if __name__ == '__main__':
    unittest.main()
