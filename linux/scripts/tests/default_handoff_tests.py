"""Exercise actual default handoff readers and writers with synthetic OCI bytes and declared unit/SDK doubles."""

from __future__ import annotations

import importlib
import json
import runpy
import sys
import unittest
from argparse import Namespace
from pathlib import Path
from typing import TYPE_CHECKING
from unittest import mock

import default_media_launch_tests as media_fixture
import gpu_handoff_tests as gpu_fixture
from native_oci_seed_tests import SEED, TOOLS, layout, seeded_copy
from normal_stage_tests import sha

if TYPE_CHECKING:
    from proof_types import Json

profile = importlib.import_module('default_handoff_profile')
MODULE, CLI = media_fixture.MODULE, gpu_fixture.CLI
ANDROID = runpy.run_path(str(TOOLS / 'launch-normal-android.py'))
SDK_LAYERS = [f'fixture-parent-{index}'.encode() for index in range(29)]


class DefaultHandoffTests(unittest.TestCase):
    def setUp(self) -> None:
        fixture = media_fixture.DefaultMediaTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        self.fixture = fixture
        self.work = fixture.work

    def saved_layout(self, context: Path, payloads: list[bytes], status: str, *, environment: list[str] | None = None) -> Json:
        manifest, document, _ = layout(context, payloads, environment=environment)
        return {'status': status, 'context': str(context), 'manifest': manifest, 'config': document['config']['digest'],
                'index_sha256': sha(context / 'index.json'), 'layers': len(payloads),
                'all_native_blob_sizes_and_sha256_verified': True, 'stopped': {'ActiveState': 'inactive', 'MainPID': '0'}}

    def selected_media(self, arch: str) -> tuple[Path, Json, Json, Json]:
        f = self.fixture
        f.sdk.update(target_arch=arch, image='ant-local/webgpu-sdk:cross-sdk-' + arch)
        f.save_sdk()
        status = 'passed-qualified-native-SDK-OCI-and-compiler-ancestry'
        f.parent.update(self.saved_layout(self.work / f'{arch}-sdk', SDK_LAYERS, status))
        f.proof_path.write_text(json.dumps(f.parent))
        sdk = dict(f.sdk, source_full_preflight_proof=str(f.full), source_full_preflight_sha256=sha(f.full))
        output = self.work / f'{arch}-media-output'
        output.mkdir()
        unit = f'webgpu-normal-media-default-{arch}-99999999-1.service'
        with (
            mock.patch.object(MODULE, 'sdk_media_parent', return_value=(f.plan, sdk, f.parent, Path(f.parent['context']))),
            mock.patch.object(MODULE, 'launch_build') as build,
        ):
            MODULE.launch(f.plan_path, f.sdk_path, f.proof_path, output, unit, f.repo, arch=arch)
        path, invocation = self.save_invocation(build)
        return path, invocation, sdk, f.parent.copy()

    def save_invocation(self, build: mock.Mock) -> tuple[Path, Json]:
        source, output, unit, image, arch, _, record, environment, driver = build.call_args.args
        command = ['systemd-run', '--user', '--expand-environment=no', '--unit=' + unit]
        for value in environment:
            command.extend(['-E', value])
        invocation = dict(record, source=str(source), output=str(output), unit=unit, image=image, target_arch=arch,
                          command=command + driver, launch_status=0, publication=False)
        path = output / 'invocation.json'
        path.write_text(json.dumps(invocation))
        return path, invocation

    def native_media(self, path: Path, media: Json, sdk: Json, *, image_target: str | None = None) -> tuple[Path, Json, Json]:
        arch = media['target_arch']
        context = self.work / f'media-context-{arch}'
        status = f'passed-native-default-{arch}-Media-OCI-and-SDK-ancestry-only'
        proof = self.saved_layout(context, [*SDK_LAYERS, b'Media'], status, environment=self.image_environment(image_target or arch))
        proof.update(Media_invocation=str(path), Media_invocation_sha256=sha(path), source_revision=media['source_revision'],
                     parent_OCI_proof_sha256=media['parent_OCI_proof_sha256'], matched_SDK_layers_and_diffIDs=sdk['layers'],
                     export_transport={'producer_status': 0, 'extractor_status': 0}, parent_layer_reuse_verified=True)
        proof_path = context.with_suffix('.proof-stopped.json')
        proof_path.write_text(json.dumps(proof))
        actual = {'image': media['image'], 'manifest': proof['manifest'], 'config': proof['config']}
        return proof_path, proof, actual

    def image_environment(self, arch: str) -> list[str]:
        return [f'TARGET_ARCH={arch}', f'TARGETARCH={arch}', 'BUILD_MODE=cross', 'BUILDPLATFORM=linux/amd64',
                'ENABLE_AMD=false', 'ENABLE_NVIDIA=false']

    def test_all_default_media_lanes_continue_through_android_command_and_reader(self) -> None:
        for arch in ('amd64', 'arm64', 'riscv64'):
            with self.subTest(arch=arch):
                self.check_default_lane(arch)

    def check_default_lane(self, arch: str) -> None:
        f = self.fixture
        path, media, sdk, parent = self.selected_media(arch)
        context = Path(parent['context'])
        unit = f'webgpu-normal-android-default-{arch}-99999999-1.service'
        output = self.work / f'{arch}-android-output'
        output.mkdir()
        proof_path, proof, actual = self.native_media(path, media, parent)
        with (
            mock.patch.object(profile, 'sdk_media_parent', return_value=(f.plan, sdk, parent, context)) as reader,
            mock.patch.object(profile, 'actual_image', return_value=actual),
            mock.patch.object(profile, 'launch_build', return_value=47) as build,
        ):
            self.assertEqual(profile.launch_default_android(f.plan_path, path, proof_path, output, unit, f.repo), 47)
            reader.assert_called_once_with(f.plan_path, f.sdk_path, f.proof_path, arch=arch)
            android_path, android = self.save_invocation(build)
            self.assertEqual(profile.load_default_android(f.plan_path, android_path), (f.plan, android, proof))
        self.assertEqual(android['image'], f.repo + ':cross-android-' + arch)
        self.assertEqual(android['target_arch'], arch)
        self.assertEqual(android['command'][-10:-4], ['/bin/bash', str(self.work / 'linux/scripts/build-cross-stage.sh'), '--stage', 'android', '--arch', arch])
        self.assertIn(f"CROSS_ANDROID_BASE_IMAGE={f.repo}@{proof['manifest']}", android['command'])
        self.assertIn('CROSS_ANDROID_BASE_CONTEXT=' + proof['context'], android['command'])
        self.assertEqual(android['Media_layers_rehashed'], 30)
        self.assertEqual(android['SDK_layers_matched'], 29)
        self.assertFalse(android['GPU_or_FINAL_acceptance'])
        self.assertEqual(build.call_args.args[5], f.plan['required_bytes'])
        self.check_android_export(android_path, android, proof_path, proof)
        with (
            mock.patch.object(profile, 'load_default_media', return_value=(f.plan, media, parent)),
            mock.patch.object(profile, 'actual_image', return_value=actual),
            mock.patch.object(profile, 'launch_build') as no_launch,
            self.assertRaisesRegex(AssertionError, 'unit or target'),
        ):
            profile.launch_default_android(f.plan_path, path, proof_path, output, 'wrong.service', f.repo)
        no_launch.assert_not_called()

    def check_android_export(self, path: Path, android: Json, parent_path: Path, parent: Json) -> None:
        arch = android['target_arch']
        context = self.work / f'android-context-{arch}'
        status = f'passed-native-default-{arch}-Android-OCI-and-Media-ancestry-only'
        child = self.saved_layout(context, [*SDK_LAYERS, b'Media', b'Android'], status, environment=self.image_environment(arch))
        args = Namespace(context=context, android_invocation=path, unit=f'webgpu-normal-android-export-default-{arch}-99999999-1.service')
        stopped = self.seal_export(args, path, android, child, parent_path, parent, 'Android')
        self.assertEqual(stopped['status'], status)
        self.assertEqual(stopped['matched_Media_layers_and_diffIDs'], 30)
        self.assertFalse(stopped['GPU_or_FINAL_acceptance'])
        verified, verified_path, _ = SEED['parent_layout'](args.context.with_suffix('.proof-stopped.json'))
        self.assertEqual(verified, stopped)
        self.assertEqual(verified_path, args.context)

    def test_default_media_refuses_changed_identity_environment_and_flags(self) -> None:
        path, media, sdk, parent = self.selected_media('arm64')
        for field, value in [('variant', 'rocm'), ('stage', 'android'), ('launch_status', 47), ('publication', True),
                             ('producer_source_unchanged', False), ('source_full_preflight_passed', False),
                             ('parent_manifest', 'wrong'), ('parent_kind', 'GPU'), ('SDK_layers_rehashed', 28),
                             ('compiler_layers_matched', 25), ('ORT_WEB_REQUIRED', 0), ('ORT_WASM_WEBGPU_FLAVORS', False),
                             ('source_revision', 'wrong'), ('parent_OCI_proof_sha256', 'wrong'), ('unit', 'wrong.service'),
                             ('image', 'ant-local/webgpu-fixture:cross-media-riscv64')]:
            path.write_text(json.dumps(dict(media, **{field: value})))
            with (
                self.subTest(field=field),
                mock.patch.object(profile, 'sdk_media_parent', return_value=(self.fixture.plan, sdk, parent, Path(parent['context']))),
                self.assertRaises(AssertionError),
            ):
                profile.load_default_media(self.fixture.plan_path, path)
        for flag in ('ORT_WASM_WEBGPU_FLAVORS=false', 'CROSS_MEDIA_BASE_CONTEXT=/other', 'ENABLE_NVIDIA=true', 'CROSS_VARIANT=rocm'):
            command = [*media['command'][:-10], '-E', flag, *media['command'][-10:]]
            with self.subTest(flag=flag), self.assertRaisesRegex(AssertionError, 'environment binding'):
                profile.validate_default_command(dict(media, command=command), parent, sdk, 'media')
        with self.assertRaisesRegex(AssertionError, 'parent target differs'):
            profile.validate_default_command(media, parent, dict(sdk, target_arch='riscv64'), 'media')
        with self.assertRaisesRegex(AssertionError, 'command unit differs'):
            profile.validate_default_command(dict(media, command=[value for value in media['command'] if not value.startswith('--unit=')]), parent, sdk, 'media')

    def test_same_host_oci_with_wrong_baked_target_refuses(self) -> None:
        path, media, _, parent = self.selected_media('arm64')
        proof_path, _, actual = self.native_media(path, media, parent, image_target='riscv64')
        with mock.patch.object(profile, 'actual_image', return_value=actual), self.assertRaisesRegex(AssertionError, 'image environment differs'):
            profile.default_media_layout(proof_path, path, media, parent)
        env = [*self.image_environment('arm64'), 'TARGETARCH=arm64']
        with self.assertRaisesRegex(AssertionError, 'image environment differs'):
            profile.default_image_config({'config': {'Env': env}}, 'arm64')
        proof = json.loads(proof_path.read_text())
        proof_path.unlink()
        args = Namespace(context=Path(proof['context']), media_invocation=path, unit='webgpu-normal-media-export-default-arm64-99999999-1.service')
        with self.assertRaisesRegex(AssertionError, 'image environment differs'):
            self.seal_export(args, path, media, proof, self.fixture.proof_path, parent, 'Media')
        self.assertFalse(args.context.with_suffix('.proof-stopped.json').exists())

    def test_export_seals_same_target_and_reuses_all_sdk_layers(self) -> None:
        path, media, _, parent = self.selected_media('riscv64')
        proof_path, proof, _ = self.native_media(path, media, parent)
        args = Namespace(context=Path(proof['context']), media_invocation=path, unit='webgpu-normal-media-export-default-riscv64-99999999-1.service')
        proof_path.unlink()
        stopped = self.seal_export(args, path, media, proof, self.fixture.proof_path, parent, 'Media')
        self.assertEqual(stopped['status'], 'passed-native-default-riscv64-Media-OCI-and-SDK-ancestry-only')
        self.assertEqual(stopped['matched_SDK_layers_and_diffIDs'], 29)
        self.assertFalse(stopped['GPU_or_FINAL_acceptance'])

    def seal_export(self, args: Namespace, path: Path, invocation: Json, child: Json, parent_path: Path, parent: Json, label: str) -> Json:
        kind = 'default-' + label.lower()
        seeded_copy(parent_path, args.context)
        Path(str(args.context) + '.transport.json').write_text(json.dumps({'producer_status': 0, 'extractor_status': 0}))
        actual = {'image': invocation['image'], 'manifest': child['manifest'], 'config': child['config']}
        record = {'unit': args.unit, 'context': str(args.context), label + '_invocation': str(path), label + '_invocation_sha256': sha(path),
                  'source_revision': invocation['source_revision'], 'parent_OCI_proof_sha256': invocation['parent_OCI_proof_sha256'],
                  'actual_image': actual, 'worker_inputs_sha256': CLI['worker_inputs'](kind), 'launch_status': 0}
        self.assertIn(str(TOOLS / 'default_handoff_profile.py'), record['worker_inputs_sha256'])
        args.context.with_suffix('.invocation.json').write_text(json.dumps(record))
        fixture = gpu_fixture.HandoffTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        fixture.image_identity = actual
        self.assertEqual(fixture.seal_export(args, kind=kind, invocation=invocation, parent=parent), 0)
        return json.loads(args.context.with_suffix('.proof-stopped.json').read_text())

    def test_public_clis_select_only_the_explicit_default_variant(self) -> None:
        f = self.fixture
        path, media, _, parent = self.selected_media('arm64')
        unit = 'webgpu-normal-media-export-default-arm64-99999999-1.service'
        argv = ['media-oci-handoff.py', 'seal', '--variant', 'default', '--compiler-plan', str(f.plan_path),
                '--media-invocation', str(path), '--context', str(self.work / 'media-context-export'), '--unit', unit]
        with (
            mock.patch.object(sys, 'argv', argv),
            mock.patch.object(profile, 'load_default_media', return_value=(f.plan, media, parent)) as load,
            mock.patch.dict(CLI['main_for'].__globals__, {'actual_image': mock.Mock(return_value={}), 'seal': mock.Mock(return_value=47)}) as state,
        ):
            self.assertEqual(CLI['main_for']('media', mock.Mock(side_effect=AssertionError('wrong loader'))), 47)
            load.assert_called_once_with(f.plan_path, path)
            self.assertEqual(state['seal'].call_args.args[-1], 'default-media')
        argv = ['launch-normal-android.py', '--variant', 'default', '--compiler-plan', str(f.plan_path), '--media-invocation', str(path),
                '--parent-proof', str(f.proof_path), '--output', str(f.output), '--unit', unit, '--image-repo', f.repo]
        with mock.patch.object(sys, 'argv', argv), mock.patch.object(profile, 'launch_default_android', return_value=47) as launch:
            self.assertEqual(ANDROID['main'](), 47)
            launch.assert_called_once_with(f.plan_path, path, f.proof_path, f.output, unit, f.repo)


if __name__ == '__main__':
    unittest.main()
