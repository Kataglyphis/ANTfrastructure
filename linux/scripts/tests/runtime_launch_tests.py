#!/usr/bin/env python3
"""Exercise ordinary runtime and local alias refusals with command/native fixtures; no actual runtime, registry, licences or inference proof."""

from __future__ import annotations

import copy
import importlib
import io
import json
import runpy
import shlex
import subprocess
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from typing import TypedDict
from unittest import mock

import android_handoff_tests as fixtures
import normal_stage_tests as stage_fixtures
from normal_stage_tests import STAGE

PROFILE = importlib.import_module('runtime_launch_profile')
ENTRY = runpy.run_path(str(fixtures.TOOLS / 'launch-normal-runtime.py'))


class ProfileOptions(TypedDict, total=False):
    unit: str
    prefix: str
    app_ref: str
    context: Path
    dirty: bool


class AliasOptions(TypedDict, total=False):
    inventories: list[list[dict]]
    status: int
    config: str
    manifests: list[str]
    resolved: list[dict]


class RuntimeTests(unittest.TestCase):
    def setUp(self) -> None:
        f = fixtures.AndroidTests()
        f.setUp()
        self.addCleanup(f.doCleanups)
        self.fixture = f
        self.work = f.work
        self.proof_path, context, self.parent = f.native_android()
        self.context = context.with_name(context.name + '-amd64')
        self.output = self.work / 'runtime-output'
        self.unit = 'webgpu-normal-runtime-amd64-99999999-1.service'
        self.prefix = 'ant-local/webgpu-fixture:runtime-rocm-1'
        self.app_ref = 'a' * 40
        self.actual = f.identity
        self.alias = 'docker.io/ant-local/webgpu-fixture@' + self.actual['manifest']
        self.alias_row = {'Name': self.alias, 'Digest': self.actual['manifest'], 'Platform': 'linux/amd64'}
        self.plan = f.fixture.fixture.plan
        self.plan_path = f.fixture.fixture.plan_path

    def profile_call(self, *, unit: str | None = None, prefix: str | None = None, app_ref: str | None = None,
                     context: Path | None = None, dirty: bool = False) -> tuple[int, mock.Mock]:
        original = PROFILE.checked_run
        def checked(command: list[str], **options: object) -> subprocess.CompletedProcess[str]:
            if command[0] == 'git':
                value = ' M host-tool' if dirty else ''
                if command[-1] == 'HEAD':
                    value = 'b' * 40
                return subprocess.CompletedProcess(command, 0, value, '')
            return original(command, **options)
        launcher = mock.Mock(return_value=47)
        with mock.patch.object(PROFILE, 'checked_run', side_effect=checked), mock.patch.object(PROFILE, 'launch_build', launcher), \
                mock.patch.object(PROFILE.uuid, 'uuid4', return_value=mock.Mock(hex='c' * 32)):
            result = PROFILE.launch_runtime(self.plan, self.fixture.android, self.fixture.invocation, self.parent,
                        context or self.context, self.proof_path, self.output, unit or self.unit,
                        prefix or self.prefix, app_ref or self.app_ref)
        return result, launcher

    def test_normal_driver_pins_actual_android_app_and_full_runtime_gates(self) -> None:
        result, launcher = self.profile_call()
        self.assertEqual(result, 47)
        args = launcher.call_args.args
        self.assertEqual(args[:6], (self.work, self.output, self.unit, self.prefix + '-amd64', 'amd64', 193273528320))
        self.assertEqual(args[8], ['/bin/bash', str(self.work / 'linux/scripts/build-runtime-manifest.sh'), '--image', self.prefix,
                         '--target-arches', 'amd64', '--artifact-image-prefix', 'ant-local/webgpu-fixture:cross-android-rocm',
                         '--artifact-build-mode', 'cross', '--skip-manifest'])
        expected = ['CROSS_VARIANT=rocm', 'CROSS_NO_PUSH=1', 'ENABLE_AMD=true', 'ENABLE_NVIDIA=false', 'ENABLE_DEEPSTREAM=false',
                    'ENABLE_TENSORRT=false', 'ENABLE_ROCM_ASAN=false', 'BUILD_TYPE=Release', 'TORCH_APP_MODE=all',
                    'ONNX_PACKAGE=onnxruntime', 'PYTORCH_EXTRA=pytorch-rocm10', 'APP_REF=' + self.app_ref,
                    'ARTIFACT_CONTEXT_MODE=oci', 'ARTIFACT_CONTEXT_ROOT=' + str(self.context).removesuffix('-amd64'),
                    'RUNTIME_ANDROID_PIN_amd64=' + self.alias, 'RUNTIME_WHEELS_SOURCE=image', 'RUNTIME_USE_LOCAL_CONTEXT_CHAIN=true',
                    'RUNTIME_CONTEXT_ROOT=' + str(self.output / 'runtime-contexts'), 'LOG_DIR=' + str(self.output / 'logs'),
                    'RUNTIME_REUSE_CHILDREN=0', 'RUNTIME_IMAGE_SMOKE=1', 'RUNTIME_INPUT_PREFLIGHT=1',
                    'WRAPPER_CONTENT_GATE=1', 'ANCESTRY_STAMP_ENFORCE=1', 'CROSS_RUN_ID=runtime-' + 'c' * 32,
                    'ANT_RUNTIME_ENGINE=' + str(Path.home() / '.local/bin/nerdctl'),
                    'ANT_RUNTIME_OWNER_LABEL=org.kataglyphis.normal-runtime', 'ANT_RUNTIME_RUN_ID=' + 'c' * 32]
        self.assertEqual(args[7], expected)
        self.assertEqual(launcher.call_args.kwargs['images'], (self.prefix + '-base-amd64', self.prefix + '-package-amd64', self.prefix + '-amd64'))
        record = args[6]
        self.assertEqual(record['Android_invocation_sha256'], fixtures.sha(self.fixture.invocation))
        self.assertEqual(record['parent_OCI_proof_sha256'], fixtures.sha(self.proof_path))
        self.assertEqual(record['Android_layers_rehashed'], 30)
        self.assertEqual(record['Media_layers_matched'], 29)
        self.assertEqual(record['app_ref'], self.app_ref)
        self.assertFalse(record['GPU_or_FINAL_acceptance'])
        self.assertEqual(record['host_tools_revision'], 'b' * 40)
        workers = [fixtures.TOOLS / name for name in ['runtime_launch_profile.py', 'launch-normal-runtime.py', 'normal_stage_launch.py', 'android_handoff_profile.py']]
        workers += [fixtures.TOOLS.parent / name for name in ['owned-nerdctl.py', 'owned_nerdctl_args.py', 'owned_containers.py', 'cleanup-owned-containers.py', 'host_commands.py']]
        self.assertEqual(record['selected_host_workers_sha256'], {str(path): fixtures.sha(path) for path in workers})
        self.assertEqual(record['run_id'], 'c' * 32)
        self.assertEqual(record['expected_runtime_run_id'], 'runtime-' + 'c' * 32)
        self.assertEqual(launcher.call_args.kwargs['engine_path'], str(fixtures.TOOLS.parent / 'owned-nerdctl.py'))
        self.assertEqual(launcher.call_args.kwargs['cleanup'], record['cleanup_command'])
        self.assertEqual(record['cleanup_command'], ['python3', str(fixtures.TOOLS.parent / 'cleanup-owned-containers.py'),
                         '--engine', str(Path.home() / '.local/bin/nerdctl'), '--owner-label', 'org.kataglyphis.normal-runtime',
                         '--run-id', 'c' * 32, '--output', str(self.output / 'cleanup.json')])
        with mock.patch.object(PROFILE, 'prepare_local_alias', return_value={'prepared': True}) as prepare:
            self.assertEqual(launcher.call_args.kwargs['prepare'](), {'prepared': True})
        prepare.assert_called_once_with(self.actual, self.output / 'local-alias.json')

    def test_unreviewed_runtime_scope_or_dirty_tools_refuse(self) -> None:
        cases: list[ProfileOptions] = [{'unit': 'webgpu-normal-media-amd64-99999999-1.service'}, {'prefix': 'ghcr.io/example:runtime-rocm-1'},
                        {'prefix': 'ant-local/webgpu-fixture:latest'}, {'app_ref': 'develop'},
                        {'context': self.context.with_name('missing-architecture')}, {'dirty': True}]
        for options in cases:
            with self.subTest(options=options), self.assertRaises(AssertionError):
                self.profile_call(**options)
        self.assertFalse(self.output.exists())

    def test_canonical_tag_provider_failure_and_output_shape_propagate(self) -> None:
        self.assertEqual(PROFILE.runtime_tags(self.work, self.prefix),
                         (self.prefix + '-base-amd64', self.prefix + '-package-amd64', self.prefix + '-amd64'))
        with mock.patch.object(PROFILE, 'checked_run', return_value=subprocess.CompletedProcess([], 0, 'same\nsame\n', '')), self.assertRaises(AssertionError):
            PROFILE.runtime_tags(self.work, self.prefix)
        with mock.patch.object(PROFILE, 'checked_run', side_effect=RuntimeError('provider failed')), self.assertRaisesRegex(RuntimeError, 'provider failed'):
            PROFILE.runtime_tags(self.work, self.prefix)

    def test_alias_reference_requires_local_namespace_and_exact_hashes(self) -> None:
        self.assertEqual(PROFILE.local_reference(self.actual), self.alias)
        for field, value in [('image', 'ghcr.io/example:cross-android-rocm-amd64'), ('manifest', 'tag'), ('config', 'invalid')]:
            with self.subTest(field=field), self.assertRaises(AssertionError):
                PROFILE.local_reference(dict(self.actual, **{field: value}))

    def alias_call(self, *, inventories: list[list[dict]] | None = None, status: int = 0,
                   config: str | None = None, manifests: list[str] | None = None,
                   resolved: list[dict] | None = None) -> tuple[dict, mock.Mock]:
        inventories = copy.deepcopy(inventories if inventories is not None else [[], [self.alias_row]])
        def checked(command: list[str]) -> subprocess.CompletedProcess[str]:
            if command[1] == 'images':
                return subprocess.CompletedProcess(command, 0, '\n'.join(json.dumps(row) for row in inventories.pop(0)), '')
            self.assertEqual(command[1:], ['image', 'inspect', self.actual['manifest']])
            data = resolved if resolved is not None else [{'Id': config or self.actual['config'], 'RepoDigests': manifests or ['ant-local/webgpu-fixture@' + self.actual['manifest']]}]
            return subprocess.CompletedProcess(command, 0, json.dumps(data), '')
        tagged = mock.Mock(return_value=subprocess.CompletedProcess([], status, 'tag output', 'tag error'))
        with mock.patch.object(PROFILE, 'checked_run', side_effect=checked), mock.patch.object(PROFILE.subprocess, 'run', tagged):
            result = PROFILE.prepare_local_alias(self.actual, self.work / 'alias.json')
        return result, tagged

    def test_alias_creation_uses_bare_manifest_and_records_raw_status(self) -> None:
        result, tagged = self.alias_call()
        self.assertEqual(result['local_immutable_alias']['status'], 'prepared-verified-local-immutable-alias-only')
        self.assertTrue(result['local_immutable_alias']['created'])
        self.assertEqual(result['local_immutable_alias']['tag_status'], 0)
        self.assertEqual(tagged.call_args.args[0][-4:], ['image', 'tag', self.actual['manifest'], self.alias])
        self.assertEqual(result['local_alias_receipt_sha256'], fixtures.sha(self.work / 'alias.json'))

    def test_matching_existing_alias_is_reused_without_retagging(self) -> None:
        result, tagged = self.alias_call(inventories=[[self.alias_row], [self.alias_row]])
        tagged.assert_not_called()
        self.assertFalse(result['local_immutable_alias']['created'])

    def test_alias_failures_never_become_verified_receipts(self) -> None:
        valid = {'Id': self.actual['config'], 'RepoDigests': ['ant-local/webgpu-fixture@' + self.actual['manifest']]}
        cases: list[AliasOptions] = [{'inventories': [[self.alias_row, self.alias_row]]},
                 {'inventories': [[dict(self.alias_row, Digest='sha256:' + 'e' * 64)]]},
                 {'inventories': [[dict(self.alias_row, Platform='linux/arm64')]]}, {'status': 47},
                 {'inventories': [[], []]}, {'inventories': [[], [dict(self.alias_row, Digest='sha256:' + 'e' * 64)]]},
                 {'inventories': [[], [dict(self.alias_row, Platform='linux/arm64')]]},
                 {'resolved': []}, {'resolved': [valid, valid]},
                 {'config': 'sha256:' + 'e' * 64}, {'manifests': ['wrong@sha256:' + 'e' * 64]}]
        for index, options in enumerate(cases):
            path = self.work / 'alias.json'
            if path.exists():
                path.unlink()
            with self.subTest(index=index), self.assertRaises(AssertionError):
                self.alias_call(**options)
            record = json.loads(path.read_text())
            self.assertNotEqual(record['status'], 'prepared-verified-local-immutable-alias-only')
            if 'status' in options:
                self.assertEqual(record['tag_status'], 47)

    def test_existing_alias_evidence_is_preserved(self) -> None:
        path = self.work / 'alias.json'
        path.write_text('previous evidence')
        with mock.patch.object(PROFILE, 'checked_run') as called, self.assertRaises(AssertionError):
            PROFILE.prepare_local_alias(self.actual, path)
        called.assert_not_called()
        self.assertEqual(path.read_text(), 'previous evidence')

    def test_dangling_alias_receipt_symlink_is_preserved(self) -> None:
        path = self.work / 'alias.json'
        path.symlink_to(self.work / 'missing-evidence')
        with mock.patch.object(PROFILE, 'checked_run') as called, self.assertRaises(AssertionError):
            PROFILE.prepare_local_alias(self.actual, path)
        called.assert_not_called()
        self.assertTrue(path.is_symlink())
        self.assertFalse((self.work / 'missing-evidence').exists())

    def test_alias_inventory_selects_the_exact_canonical_name(self) -> None:
        rows = [dict(self.alias_row, Name='other'), self.alias_row]
        with mock.patch.object(PROFILE, 'checked_run', return_value=subprocess.CompletedProcess([], 0, '\n'.join(json.dumps(row) for row in rows), '')):
            self.assertEqual(PROFILE.alias_inventory('engine', self.alias), [self.alias_row])

    def test_cli_delegates_actual_android_bindings_and_raw_status(self) -> None:
        argv = ['launch-normal-runtime.py', '--compiler-plan', str(self.plan_path), '--android-invocation', str(self.fixture.invocation),
                '--parent-proof', str(self.proof_path), '--output', str(self.output), '--unit', self.unit,
                '--image-prefix', self.prefix, '--app-ref', self.app_ref]
        loader = mock.Mock(return_value=(self.plan, self.fixture.android, self.fixture.parent))
        parent = mock.Mock(return_value=(self.parent, self.context))
        launcher = mock.Mock(return_value=47)
        with mock.patch.object(sys, 'argv', argv), mock.patch.dict(ENTRY['main'].__globals__, {'load_android': loader, 'android_layout': parent, 'launch_runtime': launcher}):
            self.assertEqual(ENTRY['main'](), 47)
        loader.assert_called_once_with(self.plan_path, self.fixture.invocation)
        parent.assert_called_once_with(self.proof_path, self.fixture.invocation, self.fixture.android, self.fixture.parent)
        self.assertEqual(launcher.call_args.args, (self.plan, self.fixture.android, self.fixture.invocation, self.parent, self.context,
                         self.proof_path, self.output, self.unit, self.prefix, self.app_ref))

    def common_call(self, *, prepare: mock.Mock, busy: bool = False,
                    cleanup: list[str] | None = None, engine_path: str | None = None) -> tuple[int, mock.Mock]:
        def execute(command: list[str], **options: object) -> subprocess.CompletedProcess[str]:
            self.assertTrue(prepare.called, 'preparation must precede a real unit start')
            self.assertIn('command', json.loads((self.output / 'invocation.json').read_text()))
            return subprocess.CompletedProcess(command, 47, 'transport-out', 'transport-err')
        transport = mock.Mock(side_effect=execute)
        self.last_transport = transport
        host = mock.Mock(return_value=self.work / 'build-temporary', side_effect=RuntimeError('busy') if busy else None)
        with mock.patch.object(STAGE, 'host_admission', host), mock.patch.object(runpy, 'run_path', return_value={'require_build_disk': mock.Mock(return_value={'available_bytes': 200 * 1024**3})}), \
                mock.patch.object(STAGE.subprocess, 'run', transport), mock.patch.object(sys, 'path', sys.path.copy()), redirect_stdout(io.StringIO()):
            result = STAGE.launch_build(self.work, self.output, self.unit, self.prefix + '-amd64', 'amd64', 193273528320,
                        {'parent_manifest': self.actual['manifest']}, ['APP_REF=' + self.app_ref], ['driver', 'argument with spaces'],
                        images=(self.prefix + '-base-amd64', self.prefix + '-package-amd64', self.prefix + '-amd64'),
                        prepare=prepare, cleanup=cleanup, engine_path=engine_path)
        host.assert_called_once_with(self.unit, self.output, (self.prefix + '-base-amd64', self.prefix + '-package-amd64', self.prefix + '-amd64'))
        return result, transport

    def test_host_admission_protects_every_runtime_tag_and_ambient_mode(self) -> None:
        f = stage_fixtures.StageTests()
        f.setUp()
        self.addCleanup(f.doCleanups)
        images = (self.prefix + '-base-amd64', self.prefix + '-package-amd64', self.prefix + '-amd64')
        f.host_values = {'unit': 'not-found\n'}
        with mock.patch.object(Path, 'home', return_value=f.work), mock.patch.object(STAGE, 'checked_run', side_effect=f.host_command):
            self.assertEqual(STAGE.host_admission(self.unit, f.output, images), f.work / '.cache' / self.unit.removesuffix('.service'))
            for image in images:
                repository, tag = image.rsplit(':', 1)
                f.host_values = {'unit': 'not-found\n', 'images': json.dumps({'Repository': repository, 'Tag': tag})}
                with self.subTest(image=image), self.assertRaises(AssertionError):
                    STAGE.host_admission(self.unit, f.output, images)
            for command in ['bash build-runtime-manifest.sh --image other', 'bash build-runtime-artifacts.sh', 'bash build-cross-stage.sh --stage sdk']:
                f.host_values = {'unit': 'not-found\n', 'processes': command + '\n'}
                with self.subTest(command=command), self.assertRaises(AssertionError):
                    STAGE.host_admission(self.unit, f.output, images)
            for flag in ['RUNTIME_IMAGE_SMOKE=0', 'ARTIFACT_CONTEXT_ROOT=/foreign', 'WRAPPER_CONTENT_GATE=0',
                         'TORCH_APP_MODE=none', 'APP_REF=develop', 'ONNX_PACKAGE=foreign', 'PYTORCH_EXTRA=foreign',
                         'HOST_PAYLOAD_ARCHES=none', 'BASE_PARENT_IMAGE=foreign', 'BASE_DOCKERFILE_PATH=foreign',
                         'PACKAGE_DOCKERFILE_PATH=foreign', 'PACKAGE_DOCKERFILE_TARGET=foreign', 'ANCESTRY_STAMP_ENFORCE=0']:
                f.host_values = {'unit': 'not-found\n', 'manager': flag + '\n'}
                with self.subTest(flag=flag), self.assertRaises(AssertionError):
                    STAGE.host_admission(self.unit, f.output, images)

    def test_shared_transport_runs_preparation_and_preserves_status(self) -> None:
        prepare = mock.Mock(return_value={'prepared': True})
        result, transport = self.common_call(prepare=prepare)
        self.assertEqual(result, 47)
        prepare.assert_called_once_with()
        record = json.loads((self.output / 'invocation.json').read_text())
        self.assertTrue(record['prepared'])
        self.assertEqual(record['launch_status'], 47)
        self.assertEqual(transport.call_args.args[0][-2:], ['driver', 'argument with spaces'])

    def test_cleanup_property_and_engine_are_installed_before_start(self) -> None:
        cleanup = ['python3', 'path with spaces/cleanup.py', '--engine', '/actual/nerdctl', '--run-id', 'c' * 32]
        _, transport = self.common_call(prepare=mock.Mock(return_value={}), cleanup=cleanup, engine_path='/actual/owned-nerdctl.py')
        command = transport.call_args.args[0]
        property_value = next(value for value in command if value.startswith('ExecStopPost='))
        self.assertEqual(shlex.split(property_value.split('=', 1)[1]), cleanup)
        self.assertLess(command.index(property_value), command.index('driver'))
        self.assertIn('NERDCTL_BIN=/actual/owned-nerdctl.py', command)

    def test_busy_admission_prevents_preparation_and_unit_launch(self) -> None:
        prepare = mock.Mock()
        with self.assertRaisesRegex(RuntimeError, 'busy'):
            self.common_call(prepare=prepare, busy=True)
        prepare.assert_not_called()
        self.last_transport.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_preparation_failure_retains_unlaunched_attempt(self) -> None:
        prepare = mock.Mock(side_effect=RuntimeError('alias failed'))
        with self.assertRaisesRegex(RuntimeError, 'alias failed'):
            self.common_call(prepare=prepare)
        self.last_transport.assert_not_called()
        record = json.loads((self.output / 'invocation.json').read_text())
        self.assertNotIn('launch_status', record)
        self.assertFalse(record['publication'])


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0], *sys.argv[1:]])
