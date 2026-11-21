#!/usr/bin/env python3
"""Check native Media/Android bindings with real synthetic OCI bytes; no real source build, authenticated receipts or acceptance."""

from __future__ import annotations

import argparse
import copy
import importlib
import json
import runpy
import sys
import unittest
from pathlib import Path
from typing import TYPE_CHECKING
from unittest import mock

import gpu_handoff_tests as fixtures
from native_oci_seed_tests import layout, seeded_copy
from normal_stage_tests import STAGE, sha

if TYPE_CHECKING:
    from typing import Any

PROFILE = importlib.import_module('media_handoff_profile')
TOOLS = fixtures.TOOLS
EXPORT = runpy.run_path(str(TOOLS / 'media-oci-handoff.py'))
ANDROID = runpy.run_path(str(TOOLS / 'launch-normal-android.py'))


class MediaTests(unittest.TestCase):
    def setUp(self) -> None:
        f = fixtures.HandoffTests()
        f.setUp()
        self.addCleanup(f.doCleanups)
        self.fixture = f
        self.work = f.work
        self.gpu_path, self.gpu_context, self.parent = f.native_gpu()
        self.output = self.work / 'media-output'
        self.output.mkdir()
        self.invocation = self.output / 'invocation.json'
        self.unit = 'webgpu-normal-media-amd64-99999999-1.service'
        self.image = 'ant-local/webgpu-fixture:cross-media-rocm-amd64'
        command = ['systemd-run', '--user', '--expand-environment=no', '-E', 'CROSS_VARIANT=rocm',
                   '-E', 'CROSS_MEDIA_BASE_CONTEXT=' + str(self.gpu_context),
                   '-E', 'CROSS_MEDIA_BASE_IMAGE=ant-local/webgpu-fixture@' + self.parent['manifest'],
                   '-E', 'ORT_WEB_REQUIRED=1', '-E', 'ORT_WASM_WEBGPU_FLAVORS=true',
                   '/bin/bash', str(self.work / 'linux/scripts/build-cross-stage.sh'), '--stage', 'media',
                   '--arch', 'amd64', '--image-repo', 'ant-local/webgpu-fixture', '--log-dir', str(self.output / 'logs')]
        self.media: dict[str, Any] = {name: f.gpu[name] for name in ('source', 'source_revision', 'source_full_preflight_proof', 'source_full_preflight_sha256')}
        self.media.update(unit=self.unit, target_arch='amd64', output=str(self.output), image=self.image, command=command,
                          launch_status=0, publication=False, source_full_preflight_passed=True, producer_source_unchanged=True,
                          parent_source_revision=f.gpu['source_revision'], GPU_invocation=str(f.invocation),
                          GPU_invocation_sha256=sha(f.invocation), parent_OCI_proof=str(self.gpu_path),
                          parent_OCI_proof_sha256=sha(self.gpu_path), parent_manifest=self.parent['manifest'],
                          parent_config=self.parent['config'], parent_OCI_index_sha256=self.parent['index_sha256'],
                          GPU_layers_rehashed=28, SDK_layers_matched=27, ORT_WEB_REQUIRED=1, ORT_WASM_WEBGPU_FLAVORS=True)
        self.save_media()

    def save_media(self) -> None:
        self.invocation.write_text(json.dumps(self.media))

    def load(self) -> tuple[dict, dict, dict]:
        self.save_media()
        with mock.patch.object(PROFILE, 'load_gpu', return_value=(self.fixture.plan, self.fixture.gpu, self.fixture.parent)) as gpu, \
                mock.patch.object(PROFILE, 'gpu_layout', return_value=(self.parent, self.gpu_context)) as parent:
            result = PROFILE.load_media(self.fixture.plan_path, self.invocation)
        gpu.assert_called_once_with(self.fixture.plan_path, self.fixture.invocation)
        parent.assert_called_once_with(self.gpu_path, self.fixture.invocation, self.fixture.gpu, self.fixture.parent)
        return result

    def test_media_keeps_exact_gpu_source_ancestry_and_both_wasm_modes(self) -> None:
        self.assertEqual(self.load(), (self.fixture.plan, self.media, self.parent))
        changes = [('source', 'wrong'), ('source_revision', 'wrong'), ('source_full_preflight_proof', 'wrong'),
                   ('source_full_preflight_sha256', 'wrong'), ('parent_source_revision', 'wrong'), ('GPU_layers_rehashed', 27),
                   ('SDK_layers_matched', 26), ('ORT_WEB_REQUIRED', 0), ('ORT_WASM_WEBGPU_FLAVORS', False),
                   ('target_arch', 'arm64'), ('unit', self.fixture.unit), ('publication', True),
                   ('launch_status', 47), ('source_full_preflight_passed', False), ('producer_source_unchanged', False)]
        for field, value in changes:
            candidate = dict(self.media, **{field: value})
            with self.subTest(field=field), self.assertRaises(AssertionError):
                PROFILE.validate_media(candidate, self.parent, self.fixture.gpu)

    def test_media_command_flags_and_source_parent_cannot_be_replaced(self) -> None:
        for before, after in [('ORT_WEB_REQUIRED=1', 'ORT_WEB_REQUIRED=0'), ('ORT_WASM_WEBGPU_FLAVORS=true', 'ORT_WASM_WEBGPU_FLAVORS=false'),
                              ('CROSS_VARIANT=rocm', 'CROSS_VARIANT=nvidia'),
                              ('CROSS_MEDIA_BASE_CONTEXT=' + str(self.gpu_context), 'unrelated-context'),
                              ('CROSS_MEDIA_BASE_IMAGE=ant-local/webgpu-fixture@' + self.parent['manifest'], 'CROSS_MEDIA_BASE_IMAGE=fixture:tag')]:
            candidate = copy.deepcopy(self.media)
            candidate['command'][candidate['command'].index(before)] = after
            with self.subTest(before=before), self.assertRaises(AssertionError):
                PROFILE.validate_media(candidate, self.parent, self.fixture.gpu)

    def test_media_load_rejects_changed_receipt_bytes_and_output_binding(self) -> None:
        gpu_result = (self.fixture.plan, self.fixture.gpu, self.fixture.parent)
        for field in ('GPU_invocation_sha256', 'parent_OCI_proof_sha256', 'output'):
            original = self.media[field]
            self.media[field] = 'wrong'
            self.save_media()
            with mock.patch.object(PROFILE, 'load_gpu', return_value=gpu_result) as gpu, \
                    mock.patch.object(PROFILE, 'gpu_layout', return_value=(self.parent, self.gpu_context)), \
                    self.subTest(field=field), self.assertRaises(AssertionError):
                PROFILE.load_media(self.fixture.plan_path, self.invocation)
            gpu.assert_not_called()
            self.media[field] = original

    def native_media(self) -> tuple[Path, Path, dict[str, Any]]:
        self.save_media()
        context = self.work / 'media-context-current'
        native = layout(context, [*[f'compiler-{index}'.encode() for index in range(26)], b'SDK layer', b'GPU layer', b'Media layer'])
        proof = {'status': 'passed-native-ROCm-Media-OCI-and-GPU-ancestry-only', 'Media_invocation': str(self.invocation),
                 'Media_invocation_sha256': sha(self.invocation), 'source_revision': self.media['source_revision'],
                 'parent_OCI_proof_sha256': self.media['parent_OCI_proof_sha256'],
                 'export_transport': {'producer_status': 0, 'extractor_status': 0}, 'parent_layer_reuse_verified': True,
                 'matched_GPU_layers_and_diffIDs': 28, 'all_native_blob_sizes_and_sha256_verified': True,
                 'context': str(context), 'manifest': native[0], 'config': native[1]['config']['digest'],
                 'index_sha256': sha(context / 'index.json'), 'layers': 29,
                 'stopped': {'ActiveState': 'inactive', 'MainPID': '0'}}
        path = self.work / 'media-proof.json'
        path.write_text(json.dumps(proof))
        self.identity = {'image': self.image, 'manifest': proof['manifest'], 'config': proof['config']}
        return path, context, proof

    def test_media_layout_requires_exact_subject_gpu_ancestry_and_transport(self) -> None:
        path, context, proof = self.native_media()
        self.assertEqual(PROFILE.STATUS, 'passed-native-ROCm-Media-OCI-and-GPU-ancestry-only')
        with mock.patch.object(PROFILE, 'actual_image', return_value=self.identity):
            self.assertEqual(PROFILE.media_layout(path, self.invocation, self.media, self.parent), (proof, context))
            for field, value in [('status', 'pending'), ('Media_invocation', 'wrong'), ('Media_invocation_sha256', 'wrong'),
                                 ('source_revision', 'wrong'), ('parent_OCI_proof_sha256', 'wrong'), ('parent_layer_reuse_verified', False),
                                 ('export_transport', {'producer_status': 47, 'extractor_status': 0}), ('matched_GPU_layers_and_diffIDs', 27)]:
                path.write_text(json.dumps(dict(proof, **{field: value})))
                with self.subTest(field=field), self.assertRaises(AssertionError):
                    PROFILE.media_layout(path, self.invocation, self.media, self.parent)
            path.write_text(json.dumps(proof))
            for field in ('manifest', 'config'):
                previous = self.identity[field]
                self.identity[field] = 'wrong'
                with self.subTest(field=field), self.assertRaisesRegex(AssertionError, 'Engine Media'):
                    PROFILE.media_layout(path, self.invocation, self.media, self.parent)
                self.identity[field] = previous

    def test_valid_unrelated_media_bytes_cannot_substitute_gpu_parent(self) -> None:
        path, _, proof = self.native_media()
        other = self.work / 'unrelated Media'
        native = layout(other, [*[f'compiler-{index}'.encode() for index in range(26)], b'foreign SDK', b'GPU layer', b'Media layer'])
        proof.update(context=str(other), manifest=native[0], config=native[1]['config']['digest'],
                     index_sha256=sha(other / 'index.json'))
        path.write_text(json.dumps(proof))
        self.identity.update(manifest=proof['manifest'], config=proof['config'])
        with mock.patch.object(PROFILE, 'actual_image', return_value=self.identity), self.assertRaisesRegex(AssertionError, 'ancestry differs'):
            PROFILE.media_layout(path, self.invocation, self.media, self.parent)

    def export_args(self, context: Path | None = None) -> argparse.Namespace:
        return argparse.Namespace(context=context or self.work / 'media-context-export', media_invocation=self.invocation,
                                  unit='webgpu-normal-media-export-amd64-99999999-1.service')

    def test_media_export_launch_binds_media_identity_and_complete_worker_inputs(self) -> None:
        self.fixture.image_identity = {'image': self.image, 'manifest': 'sha256:' + 'c' * 64, 'config': 'sha256:' + 'd' * 64}
        args = self.export_args()
        self.assertEqual(self.fixture.launch_export(args, status=47, kind='media', invocation=self.media), 47)
        record = json.loads(args.context.with_suffix('.invocation.json').read_text())
        self.assertEqual(record['Media_invocation_sha256'], sha(self.invocation))
        self.assertNotIn('GPU_invocation', record)
        hashes = record['worker_inputs_sha256']
        self.assertEqual({Path(name).name for name in hashes}, {'context-management.sh', 'native_oci_seed.py', 'native_oci_layout.py',
                         'native-oci-handoff.py', 'normal_stage_launch.py', 'stage_handoff_profile.py', 'gpu_handoff_profile.py', 'gpu-oci-handoff.py',
                         'media_handoff_profile.py', 'media-oci-handoff.py'})
        for name, digest in hashes.items():
            self.assertEqual(sha(Path(name)), digest)
        with self.assertRaisesRegex(AssertionError, 'Unreviewed'):
            fixtures.CLI['worker_inputs']('package')

    def test_media_export_seal_retains_gpu_layers_and_media_scope(self) -> None:
        _, context, _ = self.native_media()
        seeded_copy(self.gpu_path, context)
        Path(str(context) + '.transport.json').write_text(json.dumps({'producer_status': 0, 'extractor_status': 0}))
        args = self.export_args(context)
        self.fixture.image_identity = self.identity
        record = {'unit': args.unit, 'context': str(context), 'Media_invocation': str(self.invocation),
                  'Media_invocation_sha256': sha(self.invocation), 'source_revision': self.media['source_revision'],
                  'parent_OCI_proof_sha256': self.media['parent_OCI_proof_sha256'], 'actual_image': self.identity,
                  'worker_inputs_sha256': fixtures.CLI['worker_inputs']('media'), 'launch_status': 0}
        context.with_suffix('.invocation.json').write_text(json.dumps(record))
        self.assertEqual(self.fixture.seal_export(args, kind='media', invocation=self.media, parent=self.parent), 0)
        proof = json.loads(context.with_suffix('.proof-stopped.json').read_text())
        self.assertEqual(proof['status'], 'passed-native-ROCm-Media-OCI-and-GPU-ancestry-only')
        self.assertEqual(proof['matched_GPU_layers_and_diffIDs'], 28)
        self.assertFalse(proof['GPU_or_FINAL_acceptance'])
        self.assertFalse(proof['complete_binary_licence_review'])
        self.assertEqual(proof['stopped']['MainPID'], '0')

    def test_media_cli_uses_the_shared_typed_transport(self) -> None:
        transport = mock.Mock(return_value=47)
        with mock.patch.dict(EXPORT['main'].__globals__, {'TRANSPORT': {'main_for': transport}}):
            self.assertEqual(EXPORT['main'](), 47)
        transport.assert_called_once_with('media', PROFILE.load_media)

    def test_media_parser_dispatch_preserves_explicit_kind_and_raw_status(self) -> None:
        args = self.export_args()
        for action in ('launch', 'seal'):
            argv = ['media-oci-handoff.py', action, '--compiler-plan', str(self.fixture.plan_path),
                    '--media-invocation', str(self.invocation), '--context', str(args.context), '--unit', args.unit]
            called = mock.Mock(return_value=47)
            with mock.patch.object(sys, 'argv', argv), mock.patch.dict(fixtures.CLI['main_for'].__globals__,
                    {'actual_image': mock.Mock(return_value={}), action: called}):
                self.assertEqual(fixtures.CLI['main_for']('media', mock.Mock(return_value=(self.fixture.plan, self.media, self.parent))), 47)
            self.assertEqual(called.call_args.args[-1], 'media')
            self.assertEqual(called.call_args.args[0].media_invocation, self.invocation)

    def test_downstream_record_rejects_an_unreviewed_parent_kind(self) -> None:
        with self.assertRaisesRegex(AssertionError, 'Unreviewed downstream parent'):
            STAGE.downstream_record(self.media, self.invocation, self.gpu_path, self.parent, 'Compiler')

    def test_android_cli_forwards_exact_media_parent_and_source_receipt(self) -> None:
        proof_path, context, proof = self.native_media()
        argv = ['launch-normal-android.py', '--compiler-plan', str(self.fixture.plan_path), '--media-invocation', str(self.invocation),
                '--parent-proof', str(proof_path), '--output', str(self.work / 'android-output'),
                '--unit', 'webgpu-normal-android-amd64-99999999-1.service', '--image-repo', 'ant-local/webgpu-fixture']
        launcher = mock.Mock(return_value=47)
        loader = mock.Mock(return_value=(self.fixture.plan, self.media, self.parent))
        native_parent = mock.Mock(return_value=(proof, context))
        with mock.patch.object(sys, 'argv', argv), mock.patch.dict(ANDROID['main'].__globals__,
                {'load_media': loader, 'media_layout': native_parent, 'launch_stage': launcher}):
            self.assertEqual(ANDROID['main'](), 47)
        loader.assert_called_once_with(self.fixture.plan_path, self.invocation)
        native_parent.assert_called_once_with(proof_path, self.invocation, self.media, self.parent)
        call = launcher.call_args
        self.assertEqual(call.args[4:8], ('android', 'amd64', context, 'ant-local/webgpu-fixture@' + proof['manifest']))
        self.assertEqual(call.args[8], 193273528320)
        record = call.args[9]
        self.assertEqual(record['Media_invocation_sha256'], sha(self.invocation))
        self.assertEqual(record['parent_OCI_proof_sha256'], sha(proof_path))
        for field in ('source_revision', 'source_full_preflight_proof', 'source_full_preflight_sha256'):
            self.assertEqual(record[field], self.media[field])
        self.assertEqual(record['parent_source_revision'], self.media['source_revision'])
        self.assertTrue(record['source_full_preflight_passed'])
        self.assertTrue(record['producer_source_unchanged'])
        self.assertEqual(record['GPU_layers_matched'], 28)
        self.assertEqual(record['Media_layers_rehashed'], 29)
        self.assertEqual(call.kwargs, {'variant': 'rocm'})


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0], *sys.argv[1:]])
