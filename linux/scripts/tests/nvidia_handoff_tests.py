"""Exercise real NVIDIA launch and OCI handoff logic with synthetic layouts and declared engine/unit doubles."""

from __future__ import annotations

import argparse
import importlib
import json
import runpy
import sys
import unittest
from pathlib import Path
from typing import TYPE_CHECKING
from unittest import mock

import default_handoff_tests as shared_fixture
from default_handoff_tests import CLI, SDK_LAYERS, TOOLS

if TYPE_CHECKING:
    from proof_types import Json

PROFILE = importlib.import_module('nvidia_handoff_profile')
GPU_LAUNCH = runpy.run_path(str(TOOLS / 'launch-normal-gpu.py'))['main']
MEDIA_LAUNCH = runpy.run_path(str(TOOLS / 'launch-normal-media.py'))['main']
ANDROID_LAUNCH = runpy.run_path(str(TOOLS / 'launch-normal-android.py'))['main']
GPU_LAYERS = [*SDK_LAYERS, b'NVIDIA CUDA and TensorRT']
MEDIA_LAYERS = [*GPU_LAYERS, b'NVIDIA Media']


class NvidiaHandoffTests(unittest.TestCase):
    def setUp(self) -> None:
        shared = shared_fixture.DefaultHandoffTests()
        shared.setUp()
        self.addCleanup(shared.doCleanups)
        self.shared, self.fixture, self.work = shared, shared.fixture, shared.work

    def unit(self, stage: str, arch: str) -> str:
        return f'webgpu-normal-{stage}-nvidia-{arch}-99999999-1.service'

    def sdk(self, arch: str) -> tuple[Json, Json, Path]:
        fixture = self.fixture
        fixture.sdk.update(target_arch=arch, image='ant-local/webgpu-sdk:cross-sdk-' + arch)
        fixture.save_sdk()
        context = self.work / (arch + '-sdk')
        fixture.parent.update(self.shared.saved_layout(context, SDK_LAYERS, 'passed-qualified-native-SDK-OCI-and-compiler-ancestry'))
        fixture.proof_path.write_text(json.dumps(fixture.parent))
        sdk = dict(fixture.sdk, source_full_preflight_proof=str(fixture.full),
                   source_full_preflight_sha256=fixture.parent['subject']['source_proof_sha256'])
        return sdk, fixture.parent.copy(), context

    def gpu(self, arch: str) -> tuple[Path, Json, tuple[Json, Json, Json, Path]]:
        f = self.fixture
        sdk, parent, context = self.sdk(arch)
        qualified = (f.plan, sdk, parent, context)
        output = self.work / (arch + '-gpu')
        with mock.patch.object(PROFILE, 'sdk_media_parent', return_value=qualified) as reader, \
                mock.patch.object(PROFILE, 'launch_build', return_value=47) as build:
            self.assertEqual(PROFILE.launch_nvidia_gpu(f.plan_path, f.sdk_path, f.proof_path,
                                                      output, self.unit('gpu', arch), f.repo, arch), 47)
        reader.assert_called_once_with(f.plan_path, f.sdk_path, f.proof_path, arch=arch)
        self.assertEqual(build.call_args.args[5], 180 * 1024**3)
        output.mkdir()
        path, invocation = self.shared.save_invocation(build)
        return path, invocation, qualified

    def baked_env(self, arch: str, stage: str) -> list[str]:
        values = [f'TARGET_ARCH={arch}', f'TARGETARCH={arch}', 'BUILD_MODE=cross', 'BUILDPLATFORM=linux/amd64',
                  'CUDA_HOME=/usr/local/cuda', 'TENSORRT_HOME=/usr/local/tensorrt']
        if stage != 'gpu':
            values += ['ENABLE_NVIDIA=true', 'ENABLE_AMD=false', 'ENABLE_TENSORRT=true']
        return values

    def export(self, path: Path, invocation: Json, parent_path: Path, parent: Json, *,
               baked_target: str | None = None, change: str | None = None) -> tuple[Path, Json]:
        arch, stage = invocation['target_arch'], invocation['stage']
        label = {'gpu': 'GPU', 'media': 'Media', 'android': 'Android'}[stage]
        case = '-mismatch' if baked_target or change else ''
        context = self.work / f'{stage}-context{case}-{arch}'
        environment = self.baked_env(baked_target or arch, stage)
        if change:
            environment.append(change)
        payloads = {'gpu': GPU_LAYERS, 'media': MEDIA_LAYERS, 'android': [*MEDIA_LAYERS, b'NVIDIA Android']}[stage]
        child = self.shared.saved_layout(context, payloads, 'synthetic child layout', environment=environment)
        args = argparse.Namespace(context=context, unit=self.unit(stage + '-export', arch), **{stage + '_invocation': path})
        stopped = self.shared.seal_export(args, path, invocation, child, parent_path, parent, label, variant='nvidia')
        return context.with_suffix('.proof-stopped.json'), stopped

    def downstream(self, arch: str, stage: str, parent_path: Path, parent_proof: Path) -> tuple[Path, Json]:
        f = self.fixture
        output = self.work / (arch + '-' + stage)
        launch = getattr(PROFILE, 'launch_nvidia_' + stage)
        with mock.patch.object(PROFILE, 'launch_build', return_value=47) as build:
            self.assertEqual(launch(f.plan_path, parent_path, parent_proof, output, self.unit(stage, arch), f.repo), 47)
        self.assertEqual(build.call_args.args[5], 300 * 1024**3)
        output.mkdir()
        return self.shared.save_invocation(build)

    def check_commands(self, arch: str, gpu: Json, media: Json, sdk_oci: Json, gpu_oci: Json) -> None:
        self.assertEqual(gpu['image'], self.fixture.repo + '-stages:cross-toolchain-nvidia-' + arch)
        self.assertEqual(media['image'], self.fixture.repo + '-stages:cross-media-nvidia-' + arch)
        self.assertIn('CROSS_GPU_BASE_IMAGE=ant-local/webgpu-sdk@' + sdk_oci['manifest'], gpu['command'])
        self.assertIn('CROSS_MEDIA_BASE_IMAGE=' + self.fixture.repo + '-stages@' + gpu_oci['manifest'], media['command'])
        for invocation in (gpu, media):
            for flag in ('ENABLE_NVIDIA=true', 'ENABLE_AMD=false', 'ENABLE_TENSORRT=true', 'CROSS_BUILD_PLATFORM=linux/amd64',
                         'CROSS_NVIDIA_SBSA=' + ('1' if arch == 'arm64' else '0'),
                         'ENABLE_DEEPSTREAM=' + ('false' if arch == 'arm64' else 'true'),
                         'CROSS_IMAGE_PRUNE=0', 'PRUNE_DUP_CACHEMOUNTS=0'):
                self.assertEqual(invocation['command'].count(flag), 1)
        for flag in ('ORT_WEB_REQUIRED=1', 'ORT_WASM_WEBGPU_FLAVORS=true', 'ORT_ENABLE_WEBGPU=true', 'ORT_WEBGPU_ALLOW_CROSS=true'):
            self.assertIn(flag, media['command'])

    def test_two_real_command_profiles_and_native_exports(self) -> None:
        for arch in ('amd64', 'arm64'):
            with self.subTest(arch=arch):
                self.check_lane(arch)

    def check_lane(self, arch: str) -> None:
        path, gpu, qualified = self.gpu(arch)
        gpu_proof, gpu_oci = self.export(path, gpu, self.fixture.proof_path, qualified[2])
        self.assertEqual(gpu_oci['status'], f'passed-native-NVIDIA-{arch}-GPU-OCI-and-SDK-ancestry-only')
        self.assertEqual(gpu_oci['matched_SDK_layers_and_diffIDs'], 29)
        actual = {'image': gpu['image'], 'manifest': gpu_oci['manifest'], 'config': gpu_oci['config']}
        with mock.patch.object(PROFILE, 'sdk_media_parent', return_value=qualified), \
                mock.patch.object(PROFILE, 'actual_image', return_value=actual):
            media_path, media = self.downstream(arch, 'media', path, gpu_proof)
            self.assertEqual(PROFILE.load_nvidia_media(self.fixture.plan_path, media_path), (self.fixture.plan, media, gpu_oci))
            media_path.write_text(json.dumps(dict(media, ORT_WASM_WEBGPU_FLAVORS=False)))
            with self.assertRaisesRegex(AssertionError, 'Wasm'):
                PROFILE.load_nvidia_media(self.fixture.plan_path, media_path)
            media_path.write_text(json.dumps(media))
        self.check_commands(arch, gpu, media, qualified[2], gpu_oci)
        proof_path, proof = self.export(media_path, media, gpu_proof, gpu_oci)
        self.assertEqual(proof['status'], f'passed-native-NVIDIA-{arch}-Media-OCI-and-GPU-ancestry-only')
        self.assertEqual(proof['matched_GPU_layers_and_diffIDs'], 30)
        self.assertFalse(proof['GPU_or_FINAL_acceptance'])
        media_actual = {'image': media['image'], 'manifest': proof['manifest'], 'config': proof['config']}
        with mock.patch.object(PROFILE, 'actual_image', return_value=media_actual):
            self.assertEqual(PROFILE.nvidia_media_layout(proof_path, media_path, media, gpu_oci), (proof, Path(proof['context'])))
        self.check_android(arch, media_path, proof_path, proof, qualified, {gpu['image']: actual, media['image']: media_actual})

    def check_android(self, arch: str, media_path: Path, media_proof: Path, media: Json,
                      qualified: tuple[Json, Json, Json, Path], images: dict[str, Json]) -> None:
        f = self.fixture
        with mock.patch.object(PROFILE, 'sdk_media_parent', return_value=qualified), \
                mock.patch.object(PROFILE, 'actual_image', side_effect=lambda record: images[record['image']]):
            path, invocation = self.downstream(arch, 'android', media_path, media_proof)
            self.assertEqual(PROFILE.load_nvidia_android(f.plan_path, path), (f.plan, invocation, media))
            for field, actual_layers, chain in (('GPU_layers_matched', 29, 'GPU'), ('Media_layers_rehashed', 30, 'Media')):
                path.write_text(json.dumps(dict(invocation, **{field: actual_layers})))
                with self.assertRaisesRegex(AssertionError, 'Android ' + chain + ' coverage'):
                    PROFILE.load_nvidia_android(f.plan_path, path)
            path.write_text(json.dumps(invocation))
        self.assertEqual(invocation['image'], f.repo + '-stages:cross-android-nvidia-' + arch)
        self.assertEqual(invocation['Media_layers_rehashed'], 31)
        self.assertIn('CROSS_ANDROID_BASE_IMAGE=' + f.repo + '-stages@' + media['manifest'], invocation['command'])
        self.assertIn('CROSS_NVIDIA_SBSA=' + ('1' if arch == 'arm64' else '0'), invocation['command'])
        self.assertNotIn('CUDA_INSTALL_COMPAT=1', invocation['command'])
        proof_path, proof = self.export(path, invocation, media_proof, media)
        self.assertEqual(proof['status'], f'passed-native-NVIDIA-{arch}-Android-OCI-and-Media-ancestry-only')
        self.assertEqual(proof['matched_Media_layers_and_diffIDs'], 31)
        self.assertFalse(proof['GPU_or_FINAL_acceptance'])
        actual = {'image': invocation['image'], 'manifest': proof['manifest'], 'config': proof['config']}
        with mock.patch.object(PROFILE, 'actual_image', return_value=actual):
            self.assertEqual(PROFILE.nvidia_android_layout(proof_path, path, invocation, media), (proof, Path(proof['context'])))
        with mock.patch.object(PROFILE, 'native_stage_layout', return_value=(proof, self.work / 'android-context-unqualified')), \
                self.assertRaisesRegex(AssertionError, 'context target suffix'):
            PROFILE.nvidia_android_layout(proof_path, path, invocation, media)
        with self.assertRaisesRegex(AssertionError, 'ENABLE_NVIDIA'):
            self.export(path, invocation, media_proof, media, change='ENABLE_NVIDIA=false')
        self.assertFalse((self.work / f'android-context-mismatch-{arch}.proof-stopped.json').exists())

    def test_refuse_changed_gpu_scope_receipt_and_command(self) -> None:
        path, gpu, qualified = self.gpu('arm64')
        plan, sdk, parent, context = qualified
        for change in ({'parent_OCI_proof_sha256': 'wrong'}, {'source_revision': 'other'},
                       {'SDK_layers_rehashed': 28}, {'compiler_layers_rehashed': 25}, {'unit': 'wrong.service'}):
            path.write_text(json.dumps(dict(gpu, **change)))
            with self.subTest(change=change), mock.patch.object(PROFILE, 'sdk_media_parent', return_value=qualified), \
                    self.assertRaises(AssertionError):
                PROFILE.load_nvidia_gpu(self.fixture.plan_path, path)
        path.write_text(json.dumps(gpu))
        with mock.patch.object(PROFILE, 'sdk_media_parent', return_value=(plan, dict(sdk, target_arch='amd64'), parent, context)), \
                self.assertRaisesRegex(AssertionError, 'parent target differs'):
            PROFILE.load_nvidia_gpu(self.fixture.plan_path, path)
        for flag in ('CROSS_NVIDIA_SBSA=0', 'ENABLE_TENSORRT=false'):
            command = [*gpu['command'][:-10], '-E', flag, *gpu['command'][-10:]]
            with self.subTest(flag=flag), self.assertRaisesRegex(AssertionError, 'environment binding'):
                PROFILE.validate_nvidia_stage(dict(gpu, command=command), parent, sdk, 'gpu', context)

    def test_gpu_export_refuses_wrong_baked_target_before_seal(self) -> None:
        path, gpu, qualified = self.gpu('arm64')
        with self.assertRaisesRegex(AssertionError, 'NVIDIA cross image environment differs'):
            self.export(path, gpu, self.fixture.proof_path, qualified[2], baked_target='amd64')
        self.assertFalse((self.work / 'gpu-context-mismatch-arm64.proof-stopped.json').exists())

    def test_media_export_refuses_disabled_baked_tensorrt(self) -> None:
        gpu_path, gpu, qualified = self.gpu('amd64')
        gpu_proof, gpu_oci = self.export(gpu_path, gpu, self.fixture.proof_path, qualified[2])
        actual = {'image': gpu['image'], 'manifest': gpu_oci['manifest'], 'config': gpu_oci['config']}
        with mock.patch.object(PROFILE, 'sdk_media_parent', return_value=qualified), \
                mock.patch.object(PROFILE, 'actual_image', return_value=actual):
            path, media = self.downstream('amd64', 'media', gpu_path, gpu_proof)
        with self.assertRaisesRegex(AssertionError, 'ENABLE_TENSORRT'):
            self.export(path, media, gpu_proof, gpu_oci, change='ENABLE_TENSORRT=false')
        self.assertFalse((self.work / 'media-context-mismatch-amd64.proof-stopped.json').exists())

    def test_nvidia_media_export_rejects_less_than_chain_floor(self) -> None:
        context = self.work / 'media-context-short'
        args = argparse.Namespace(context=context, media_invocation=self.work / 'media.invocation', unit=self.unit('media-export', 'arm64'))
        disk = mock.Mock(return_value={'available_bytes': 300 * 1024**3 - 1})
        launch = CLI['launch']
        with mock.patch.dict(launch.__globals__['COMMON'], {'state': mock.Mock(return_value={'LoadState': 'not-found'})}), \
                mock.patch.object(runpy, 'run_path', return_value={'require_build_disk': disk}), \
                self.assertRaisesRegex(AssertionError, 'NVIDIA Media export requires 300 GiB'):
            launch(args, self.fixture.plan, {}, {}, 'nvidia-media')
        self.assertFalse(context.with_suffix('.invocation.json').exists())

    def test_public_launchers_and_export_select_nvidia_explicitly(self) -> None:
        f = self.fixture
        for stage, entry, parent in (('gpu', GPU_LAUNCH, 'sdk'), ('media', MEDIA_LAUNCH, 'gpu'),
                                     ('android', ANDROID_LAUNCH, 'media')):
            unit = self.unit(stage, 'arm64')
            common = ['--variant', 'nvidia', '--compiler-plan', str(f.plan_path), '--unit', unit]
            argv = ['launcher', *common, '--' + parent + '-invocation', str(f.sdk_path),
                    '--parent-proof', str(f.proof_path), '--output', str(f.output), '--image-repo', f.repo]
            if stage == 'gpu':
                argv.extend(['--arch', 'arm64'])
            with mock.patch.object(sys, 'argv', argv), mock.patch.object(PROFILE, 'launch_nvidia_' + stage, return_value=47) as launch:
                self.assertEqual(entry(), 47)
                extra = ['arm64'] if stage == 'gpu' else []
                launch.assert_called_once_with(f.plan_path, f.sdk_path, f.proof_path, f.output, unit, f.repo, *extra)
            self.check_cli_export(stage)

    def check_cli_export(self, stage: str) -> None:
        f = self.fixture
        argv = ['export', 'seal', '--variant', 'nvidia', '--compiler-plan', str(f.plan_path),
                '--' + stage + '-invocation', str(f.sdk_path), '--context', str(self.work / (stage + '-context-export-arm64')),
                '--unit', self.unit(stage + '-export', 'arm64')]
        loader = CLI['main_for']
        seal = mock.Mock(return_value=47)
        with mock.patch.object(sys, 'argv', argv), \
                mock.patch.object(PROFILE, 'load_nvidia_' + stage, return_value=(f.plan, {'target_arch': 'arm64'}, {})) as read, \
                mock.patch.dict(loader.__globals__, {'actual_image': mock.Mock(return_value={}), 'seal': seal}):
            self.assertEqual(loader(stage, mock.Mock(side_effect=AssertionError('wrong loader'))), 47)
        read.assert_called_once_with(f.plan_path, f.sdk_path)
        self.assertEqual(seal.call_args.args[-1], 'nvidia-' + stage)
        if stage == 'android':
            argv[argv.index('--context') + 1] = str(self.work / 'android-context-export-amd64')
            with mock.patch.object(sys, 'argv', argv), \
                    mock.patch.object(PROFILE, 'load_nvidia_android', return_value=(f.plan, {'target_arch': 'arm64'}, {})), \
                    mock.patch.dict(loader.__globals__, {'actual_image': mock.Mock(return_value={}), 'seal': seal}), \
                    self.assertRaisesRegex(AssertionError, 'runtime target suffix'):
                loader(stage, mock.Mock(side_effect=AssertionError('wrong loader')))


if __name__ == '__main__':
    unittest.main()
