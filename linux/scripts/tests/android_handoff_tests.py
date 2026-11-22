#!/usr/bin/env python3
"""Check Android parent/source and native transport with synthetic bytes; no actual build, authenticated provenance or FINAL acceptance."""

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

import gpu_handoff_tests as gpu_fixtures
import media_handoff_tests as media_fixtures
from native_oci_seed_tests import layout, seeded_copy
from normal_stage_tests import sha

if TYPE_CHECKING:
    from typing import Any

PROFILE = importlib.import_module('android_handoff_profile')
TOOLS = gpu_fixtures.TOOLS
EXPORT = runpy.run_path(str(TOOLS / 'android-oci-handoff.py'))


class AndroidTests(unittest.TestCase):
    def setUp(self) -> None:
        f = media_fixtures.MediaTests()
        f.setUp()
        self.addCleanup(f.doCleanups)
        self.fixture = f
        self.work = f.work
        self.media_path, self.media_context, self.parent = f.native_media()
        self.output = self.work / 'android-output'
        self.output.mkdir()
        self.invocation = self.output / 'invocation.json'
        self.image = 'ant-local/webgpu-fixture:cross-android-rocm-amd64'
        command = ['systemd-run', '--user', '--expand-environment=no', '-E', 'CROSS_VARIANT=rocm',
                   '-E', 'CROSS_ANDROID_BASE_CONTEXT=' + str(self.media_context),
                   '-E', 'CROSS_ANDROID_BASE_IMAGE=ant-local/webgpu-fixture@' + self.parent['manifest'],
                   '/bin/bash', str(self.work / 'linux/scripts/build-cross-stage.sh'), '--stage', 'android',
                   '--arch', 'amd64', '--image-repo', 'ant-local/webgpu-fixture', '--log-dir', str(self.output / 'logs')]
        self.android: dict[str, Any] = {name: f.media[name] for name in ('source', 'source_revision', 'source_full_preflight_proof', 'source_full_preflight_sha256')}
        self.android.update(stage='android', variant='rocm', unit='webgpu-normal-android-amd64-99999999-1.service',
                            target_arch='amd64', output=str(self.output), image=self.image, command=command,
                            launch_status=0, publication=False, source_full_preflight_passed=True, producer_source_unchanged=True,
                            parent_source_revision=f.media['source_revision'], Media_invocation=str(f.invocation),
                            Media_invocation_sha256=sha(f.invocation), parent_OCI_proof=str(self.media_path),
                            parent_OCI_proof_sha256=sha(self.media_path), parent_manifest=self.parent['manifest'],
                            parent_config=self.parent['config'], parent_OCI_index_sha256=self.parent['index_sha256'],
                            Media_layers_rehashed=29, GPU_layers_matched=28)
        self.save_android()

    def save_android(self) -> None:
        self.invocation.write_text(json.dumps(self.android))

    def load(self) -> tuple[dict, dict, dict]:
        self.save_android()
        with mock.patch.object(PROFILE, 'load_media', return_value=(self.fixture.fixture.plan, self.fixture.media, self.fixture.parent)) as media, \
                mock.patch.object(PROFILE, 'media_layout', return_value=(self.parent, self.media_context)) as parent:
            result = PROFILE.load_android(self.fixture.fixture.plan_path, self.invocation)
        media.assert_called_once_with(self.fixture.fixture.plan_path, self.fixture.invocation)
        parent.assert_called_once_with(self.media_path, self.fixture.invocation, self.fixture.media, self.fixture.parent)
        return result

    def test_source_metadata_and_native_media_coverage_are_bound(self) -> None:
        self.assertEqual(self.load(), (self.fixture.fixture.plan, self.android, self.parent))
        changes = [('stage', 'media'), ('variant', 'nvidia'), ('source', 'wrong'), ('source_revision', 'wrong'),
                   ('source_full_preflight_proof', 'wrong'), ('source_full_preflight_sha256', 'wrong'),
                   ('parent_source_revision', 'wrong'), ('Media_layers_rehashed', 28), ('GPU_layers_matched', 27),
                   ('target_arch', 'arm64'), ('unit', self.fixture.unit), ('publication', True), ('launch_status', 47),
                   ('source_full_preflight_passed', False), ('producer_source_unchanged', False)]
        for field, value in changes:
            with self.subTest(field=field), self.assertRaises(AssertionError):
                PROFILE.validate_android(dict(self.android, **{field: value}), self.parent, self.fixture.media)

    def test_android_command_keeps_variant_source_and_native_parent(self) -> None:
        for before, after in [('CROSS_VARIANT=rocm', 'CROSS_VARIANT=nvidia'),
                              ('CROSS_ANDROID_BASE_CONTEXT=' + str(self.media_context), 'unrelated-context'),
                              ('CROSS_ANDROID_BASE_IMAGE=ant-local/webgpu-fixture@' + self.parent['manifest'], 'CROSS_ANDROID_BASE_IMAGE=fixture:tag'),
                              (str(self.work / 'linux/scripts/build-cross-stage.sh'), '/unrelated-driver')]:
            candidate = copy.deepcopy(self.android)
            candidate['command'][candidate['command'].index(before)] = after
            with self.subTest(before=before), self.assertRaises(AssertionError):
                PROFILE.validate_android(candidate, self.parent, self.fixture.media)

    def test_load_rejects_changed_media_receipts_before_parent_callbacks(self) -> None:
        for field in ('Media_invocation_sha256', 'parent_OCI_proof_sha256', 'output'):
            previous = self.android[field]
            self.android[field] = 'wrong'
            self.save_android()
            with mock.patch.object(PROFILE, 'load_media') as loader, self.subTest(field=field), self.assertRaises(AssertionError):
                PROFILE.load_android(self.fixture.fixture.plan_path, self.invocation)
            loader.assert_not_called()
            self.android[field] = previous

    def test_parent_failures_propagate_without_validating_a_child(self) -> None:
        with mock.patch.object(PROFILE, 'load_media', side_effect=RuntimeError('upstream proof failed')), \
                self.assertRaisesRegex(RuntimeError, 'upstream proof failed'):
            PROFILE.load_android(self.fixture.fixture.plan_path, self.invocation)
        with mock.patch.object(PROFILE, 'load_media', return_value=(self.fixture.fixture.plan, self.fixture.media, self.fixture.parent)), \
                mock.patch.object(PROFILE, 'media_layout', side_effect=RuntimeError('native parent failed')), \
                self.assertRaisesRegex(RuntimeError, 'native parent failed'):
            PROFILE.load_android(self.fixture.fixture.plan_path, self.invocation)

    def test_load_revalidates_current_android_and_inherited_media_flags(self) -> None:
        self.android['parent_source_revision'] = 'wrong'
        with self.assertRaises(AssertionError):
            self.load()
        self.fixture.media['ORT_WEB_REQUIRED'] = 0
        with self.assertRaises(AssertionError):
            self.fixture.load()

    def native_android(self) -> tuple[Path, Path, dict[str, Any]]:
        context = self.work / 'android-context-current'
        layers = [*[f'compiler-{index}'.encode() for index in range(26)], b'SDK layer', b'GPU layer', b'Media layer', b'Android layer']
        native = layout(context, layers)
        proof = {'status': 'passed-native-ROCm-Android-OCI-and-Media-ancestry-only', 'Android_invocation': str(self.invocation),
                 'Android_invocation_sha256': sha(self.invocation), 'source_revision': self.android['source_revision'],
                 'parent_OCI_proof_sha256': self.android['parent_OCI_proof_sha256'],
                 'export_transport': {'producer_status': 0, 'extractor_status': 0}, 'parent_layer_reuse_verified': True,
                 'matched_Media_layers_and_diffIDs': 29, 'all_native_blob_sizes_and_sha256_verified': True,
                 'context': str(context), 'manifest': native[0], 'config': native[1]['config']['digest'],
                 'index_sha256': sha(context / 'index.json'), 'layers': 30,
                 'stopped': {'ActiveState': 'inactive', 'MainPID': '0'}}
        path = self.work / 'android-proof.json'
        path.write_text(json.dumps(proof))
        self.identity = {'image': self.image, 'manifest': proof['manifest'], 'config': proof['config']}
        return path, context, proof

    def test_native_android_binds_subject_source_transport_and_media_layers(self) -> None:
        path, context, proof = self.native_android()
        self.assertEqual(PROFILE.STATUS, 'passed-native-ROCm-Android-OCI-and-Media-ancestry-only')
        with mock.patch.object(PROFILE, 'actual_image', return_value=self.identity):
            self.assertEqual(PROFILE.android_layout(path, self.invocation, self.android, self.parent), (proof, context))
            for field, value in [('status', 'pending'), ('status', 'passed-native-ROCm-Media-OCI-and-GPU-ancestry-only'), ('Android_invocation', 'wrong'), ('Android_invocation_sha256', 'wrong'),
                                 ('source_revision', 'wrong'), ('parent_OCI_proof_sha256', 'wrong'), ('parent_layer_reuse_verified', False),
                                 ('export_transport', {'producer_status': 0, 'extractor_status': 47}), ('matched_Media_layers_and_diffIDs', 28)]:
                path.write_text(json.dumps(dict(proof, **{field: value})))
                with self.subTest(field=field), self.assertRaises(AssertionError):
                    PROFILE.android_layout(path, self.invocation, self.android, self.parent)
            path.write_text(json.dumps(proof))
            for field in ('manifest', 'config'):
                previous = self.identity[field]
                self.identity[field] = 'wrong'
                with self.subTest(field=field), self.assertRaisesRegex(AssertionError, 'Engine Android'):
                    PROFILE.android_layout(path, self.invocation, self.android, self.parent)
                self.identity[field] = previous

    def test_valid_unrelated_android_bytes_cannot_replace_the_media_parent(self) -> None:
        path, _, proof = self.native_android()
        other = self.work / 'unrelated Android'
        native = layout(other, [*[f'compiler-{index}'.encode() for index in range(26)], b'SDK layer', b'GPU layer', b'foreign Media', b'Android layer'])
        proof.update(context=str(other), manifest=native[0], config=native[1]['config']['digest'], index_sha256=sha(other / 'index.json'))
        path.write_text(json.dumps(proof))
        self.identity.update(manifest=proof['manifest'], config=proof['config'])
        with mock.patch.object(PROFILE, 'actual_image', return_value=self.identity), self.assertRaisesRegex(AssertionError, 'ancestry differs'):
            PROFILE.android_layout(path, self.invocation, self.android, self.parent)

    def export_args(self, context: Path | None = None) -> argparse.Namespace:
        return argparse.Namespace(context=context or self.work / 'android-context-export', android_invocation=self.invocation,
                                  unit='webgpu-normal-android-export-amd64-99999999-1.service')

    def test_export_launch_binds_android_subject_and_recursive_worker_closure(self) -> None:
        f = self.fixture.fixture
        f.image_identity = {'image': self.image, 'manifest': 'sha256:' + 'c' * 64, 'config': 'sha256:' + 'd' * 64}
        args = self.export_args()
        self.assertEqual(f.launch_export(args, status=47, kind='android', invocation=self.android), 47)
        record = json.loads(args.context.with_suffix('.invocation.json').read_text())
        self.assertEqual(record['Android_invocation_sha256'], sha(self.invocation))
        self.assertNotIn('GPU_invocation', record)
        self.assertNotIn('Media_invocation', record)
        self.assertEqual({Path(name).name for name in record['worker_inputs_sha256']},
                         {'context-management.sh', 'native_oci_seed.py', 'native_oci_layout.py', 'native-oci-handoff.py',
                          'normal_stage_launch.py', 'stage_handoff_profile.py', 'gpu_handoff_profile.py', 'gpu-oci-handoff.py',
                          'media_handoff_profile.py', 'media-oci-handoff.py', 'android_handoff_profile.py', 'android-oci-handoff.py'})
        for name, digest in record['worker_inputs_sha256'].items():
            self.assertEqual(sha(Path(name)), digest)

    def test_export_seal_retains_actual_media_ancestry_and_scope(self) -> None:
        _, context, _ = self.native_android()
        seeded_copy(self.media_path, context)
        Path(str(context) + '.transport.json').write_text(json.dumps({'producer_status': 0, 'extractor_status': 0}))
        args = self.export_args(context)
        f = self.fixture.fixture
        f.image_identity = self.identity
        record = {'unit': args.unit, 'context': str(context), 'Android_invocation': str(self.invocation),
                  'Android_invocation_sha256': sha(self.invocation), 'source_revision': self.android['source_revision'],
                  'parent_OCI_proof_sha256': self.android['parent_OCI_proof_sha256'], 'actual_image': self.identity,
                  'worker_inputs_sha256': gpu_fixtures.CLI['worker_inputs']('android'), 'launch_status': 0}
        context.with_suffix('.invocation.json').write_text(json.dumps(record))
        self.assertEqual(f.seal_export(args, kind='android', invocation=self.android, parent=self.parent), 0)
        proof = json.loads(context.with_suffix('.proof-stopped.json').read_text())
        self.assertEqual(proof['status'], 'passed-native-ROCm-Android-OCI-and-Media-ancestry-only')
        self.assertEqual(proof['matched_Media_layers_and_diffIDs'], 29)
        self.assertFalse(proof['GPU_or_FINAL_acceptance'])
        self.assertFalse(proof['complete_binary_licence_review'])
        self.assertEqual(proof['stopped']['MainPID'], '0')

    def test_cli_entry_uses_android_loader_and_explicit_kind(self) -> None:
        transport = mock.Mock(return_value=47)
        with mock.patch.dict(EXPORT['main'].__globals__, {'TRANSPORT': {'main_for': transport}}):
            self.assertEqual(EXPORT['main'](), 47)
        transport.assert_called_once_with('android', PROFILE.load_android)

    def test_parser_retains_android_invocation_and_raw_action_status(self) -> None:
        args = self.export_args()
        for action in ('launch', 'seal'):
            argv = ['android-oci-handoff.py', action, '--compiler-plan', str(self.fixture.fixture.plan_path),
                    '--android-invocation', str(self.invocation), '--context', str(args.context), '--unit', args.unit]
            called = mock.Mock(return_value=47)
            with mock.patch.object(sys, 'argv', argv), mock.patch.dict(gpu_fixtures.CLI['main_for'].__globals__,
                    {'actual_image': mock.Mock(return_value={}), action: called}):
                self.assertEqual(gpu_fixtures.CLI['main_for']('android', mock.Mock(return_value=(self.fixture.fixture.plan, self.android, self.parent))), 47)
            self.assertEqual(called.call_args.args[-1], 'android')
            self.assertEqual(called.call_args.args[0].android_invocation, self.invocation)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0], *sys.argv[1:]])
