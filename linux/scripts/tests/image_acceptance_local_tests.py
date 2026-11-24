"""Independent synthetic local FINAL controls; no real engine, source qualification, six-consumer execution or hardware proof."""

from __future__ import annotations

import copy
import json
import shutil
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

from image_acceptance_local_fixture import LOCAL, MAIN, NAMES, RUNTIME, LocalFixture


class LocalAcceptanceTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix='local-final-tests-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.fixture = LocalFixture(self.root)

    def passed_receipt(self) -> dict:
        with self.fixture.commands():
            MAIN.check(self.fixture.args)
        return json.loads(Path(self.fixture.args.receipt).read_text())

    def assert_retained_sources(self) -> None:
        for name in NAMES:
            source = Path(self.fixture.args.workspace) / name / "source.txt"
            self.assertEqual(source.read_text(), name + " versioned fixture\n")

    def test_full_contract_runs_all_six_without_a_registry_pull_and_keeps_bindings(self) -> None:
        receipt = self.passed_receipt()
        self.assertEqual(receipt['schema_version'], 2)
        self.assertEqual(receipt['image_transport'], 'local')
        self.assertEqual(receipt['status'], 'passed')
        self.assertEqual([row['name'] for row in receipt['consumers']], NAMES)
        self.assertEqual(len(receipt['consumers']), 6)
        self.assertEqual(receipt['local_subject'], receipt['local_subject_after'])
        self.assertEqual(receipt['local_subject']['kind'], 'local-runtime-final')
        self.assertEqual(receipt['local_subject']['config'], self.fixture.config)
        self.assertEqual(receipt['local_subject']['producer_invocation_sha256'], LOCAL.fingerprint(self.fixture.invocation_path))
        self.assertEqual(receipt['local_subject']['runtime_proof_sha256'], LOCAL.fingerprint(self.fixture.full_proof))
        self.assertEqual(receipt['local_subject']['parent_source_revision'], 'b' * 40)
        self.assertEqual(receipt['local_alias_sha256'], LOCAL.fingerprint(Path(receipt['local_alias_receipt'])))
        consumers = [command for command in self.fixture.calls if command[:2] == ['engine', 'run']]
        self.assertEqual(len(consumers), 6)
        self.assertFalse(any(command[:2] == ['engine', 'pull'] for command in self.fixture.calls))
        for command, spec in zip(consumers, self.fixture.contract['consumers']):
            self.assertEqual(command[-len(spec['command']):], spec['command'])
            self.assertEqual(command[-len(spec['command']) - 1], self.fixture.reference)
            self.assertIn('--init', command)
            self.assertEqual(command[command.index('--pull') + 1], 'never')
        self.fixture.full_source.assert_has_calls([mock.call(self.fixture.source, self.fixture.full_proof, 'a' * 40)] * 2)
        self.fixture.terminal.assert_has_calls([mock.call(self.fixture.unit)] * 2)
        self.assert_retained_sources()
        self.assertTrue((Path(self.fixture.args.workspace) / (NAMES[0] + '.log')).is_file())

    def test_registry_check_keeps_its_schema_pull_and_full_shared_runner(self) -> None:
        image = 'ghcr.io/owner/test@' + self.fixture.manifest
        self.fixture.reference = image
        self.fixture.args.image = image
        self.fixture.args.local_runtime_invocation = None
        with self.fixture.commands():
            MAIN.check(self.fixture.args)
        receipt = json.loads(Path(self.fixture.args.receipt).read_text())
        self.assertEqual(receipt['schema_version'], 1)
        self.assertEqual(receipt['status'], 'passed')
        self.assertEqual(len(receipt['consumers']), 6)
        self.assertNotIn('local_subject', receipt)
        self.assertEqual(sum(command[:2] == ['engine', 'pull'] for command in self.fixture.calls), 1)
        self.fixture.full_source.assert_not_called()
        self.fixture.terminal.assert_not_called()
        self.assert_retained_sources()

    def test_replay_cannot_silently_use_changed_producer_evidence(self) -> None:
        self.passed_receipt()
        self.fixture.args.replay = self.fixture.args.receipt
        self.fixture.args.workspace = str(self.root / 'changed-replay')
        self.fixture.args.receipt = str(self.root / 'changed-receipt.json')
        self.fixture.cleanup_path.write_text(json.dumps({**self.fixture.cleanup, 'observation':'changed'}))
        before = sum(command[:2] == ['engine', 'run'] for command in self.fixture.calls)
        with self.fixture.commands(), self.assertRaisesRegex(ValueError, 'replay producer or image identity changed'):
            MAIN.check(self.fixture.args)
        receipt = json.loads(Path(self.fixture.args.receipt).read_text())
        self.assertEqual(receipt['status'], 'failed')
        self.assertEqual(sum(command[:2] == ['engine', 'run'] for command in self.fixture.calls), before)

    def test_metadata_transport_covers_exactly_the_six_linux_lanes(self) -> None:
        for index, (variant, arch) in enumerate([('', 'amd64'), ('', 'arm64'), ('', 'riscv64'),
                                               ('rocm', 'amd64'), ('nvidia', 'amd64'), ('nvidia', 'arm64')]):
            for mode in (['export'] if variant == 'nvidia' else ['image', 'export']):
                directory = self.root / (str(index) + mode)
                directory.mkdir()
                fixture = LocalFixture(directory, arch, variant)
                if variant == 'nvidia':
                    fixture.nvidia_android()
                elif mode == 'export':
                    old_unit = fixture.unit
                    fixture.unit = old_unit.replace('runtime-', 'runtime-' + (variant or 'default') + '-')
                    fixture.invocation['unit'] = fixture.terminal.return_value['Id'] = fixture.unit
                    fixture.invocation['command'] = [value.replace('RUNTIME_WHEELS_SOURCE=image', 'RUNTIME_WHEELS_SOURCE=export').replace(old_unit, fixture.unit) for value in fixture.invocation['command']]
                    fixture.save()
                    fixture.command_android()
                with fixture.commands(), self.subTest(variant=variant, arch=arch, mode=mode):
                    MAIN.check(fixture.args)
                receipt = json.loads(Path(fixture.args.receipt).read_text())
                self.assertEqual(receipt['local_subject']['variant'], variant)
                self.assertEqual(receipt['platform'], 'linux/' + arch)
                self.assertEqual(len(receipt['consumers']), 6)

    def test_explicit_runtime_unit_never_changes_lane_or_architecture(self) -> None:
        pattern = LOCAL.producer_unit('runtime', 'amd64', '')
        for unit in ['webgpu-normal-runtime-rocm-amd64-999-1.service', 'webgpu-normal-runtime-default-arm64-999-1.service',
                     'webgpu-normal-runtime-nvidia-amd64-999-1.service', 'webgpu-normal-runtime-default-amd64-999-1.service.extra']:
            self.assertIsNone(pattern.fullmatch(unit))
        self.assertIsNone(LOCAL.producer_unit('runtime', 'amd64', 'rocm').fullmatch('webgpu-normal-runtime-default-amd64-999-1.service'))

    def test_default_android_export_flows_to_all_six_local_final_consumers(self) -> None:
        directory = self.root / 'default-foreign'
        directory.mkdir()
        f = LocalFixture(directory, 'arm64', '')
        f.command_android()
        f.android.update(stage='android', variant='default')
        f.android_path.write_text(json.dumps(f.android))
        digest = LOCAL.fingerprint(f.android_path)
        context = str(directory / 'android-context-arm64')
        f.parent.update(status='passed-native-default-arm64-Android-OCI-and-Media-ancestry-only',
                        Android_invocation=str(f.android_path), Android_invocation_sha256=digest,
                        context=context, index_sha256='f' * 64, layers=31, matched_Media_layers_and_diffIDs=30,
                        export_transport={'producer_status':0, 'extractor_status':0}, parent_layer_reuse_verified=True,
                        all_native_blob_sizes_and_sha256_verified=True)
        f.parent_path.write_text(json.dumps(f.parent))
        f.invocation.update(source_revision='b' * 40, default_android_ancestry_verified=True,
                            parent_context=context, Android_invocation_sha256=digest, parent_OCI_index_sha256='f' * 64,
                            parent_OCI_proof_sha256=LOCAL.fingerprint(f.parent_path), Android_layers_rehashed=31, Media_layers_matched=30)
        f.tag_image['Config']['Labels']['org.opencontainers.image.revision'] = 'b' * 40
        f.digest_image = copy.deepcopy(f.tag_image)
        command = f.invocation['command']
        command[command.index('RUNTIME_WHEELS_SOURCE=image')] = 'RUNTIME_WHEELS_SOURCE=export'
        command[4:4] = ['CROSS_BUILD_PLATFORM=linux/amd64', 'ARTIFACT_CONTEXT_ROOT=' + context.removesuffix('-arm64'),
                        'CROSS_IMAGE_PRUNE=0', 'PRUNE_DUP_CACHEMOUNTS=0']
        workers = RUNTIME.runtime_worker_files(f.host, default=True)
        for path in workers:
            if not path.exists():
                path.write_text('# target-specific worker identity\n')
        f.invocation['selected_host_workers_sha256'] = {str(path): LOCAL.fingerprint(path) for path in workers}
        f.save()
        with f.commands():
            MAIN.check(f.args)
        receipt = json.loads(Path(f.args.receipt).read_text())
        self.assertEqual([row['name'] for row in receipt['consumers']], NAMES)
        self.assertEqual(receipt['platform'], 'linux/arm64')
        with f.commands():
            for field, value in [('default_android_ancestry_verified', False), ('source_revision', 'c' * 40),
                                 ('parent_context', '/other/target-arm64'), ('Media_layers_matched', 9)]:
                with self.subTest(field=field), self.assertRaises(ValueError):
                    LOCAL.parent_binding({**f.invocation, field:value}, f.platform)
            wrong = dict(f.parent, status='passed-native-default-amd64-Android-OCI-and-Media-ancestry-only')
            f.parent_path.write_text(json.dumps(wrong))
            with self.assertRaisesRegex(ValueError, 'receipt scope differs'):
                LOCAL.parent_binding(dict(f.invocation, parent_OCI_proof_sha256=LOCAL.fingerprint(f.parent_path)), f.platform)

    def nvidia_fixture(self) -> LocalFixture:
        directory = self.root / 'nvidia-foreign'
        directory.mkdir()
        fixture = LocalFixture(directory, 'arm64', 'nvidia')
        fixture.nvidia_android()
        return fixture

    def test_nvidia_final_refuses_drift_in_android_scope_and_media_receipt(self) -> None:
        f = self.nvidia_fixture()
        with f.commands():
            self.assertEqual(LOCAL.parent_binding(f.invocation, f.platform), (f.android, f.parent_reference))
            for field, value in [('nvidia_android_ancestry_verified', False), ('source_revision', 'c' * 40),
                                 ('parent_context', '/other-context-arm64'), ('Media_layers_matched', 9)]:
                with self.subTest(field=field), self.assertRaises(ValueError):
                    LOCAL.parent_binding({**f.invocation, field:value}, f.platform)
            for field, value in [('status', 'passed-native-NVIDIA-amd64-Android-OCI-and-Media-ancestry-only'),
                                 ('unit', 'webgpu-normal-android-export-arm64-999-1.service'),
                                 ('stopped', {'ActiveState':'active', 'MainPID':'1'}),
                                 ('terminal_before_stop', {**f.parent['terminal_before_stop'], 'ExecMainStatus':'47'}),
                                 ('parent_OCI_proof_sha256', '0' * 64)]:
                f.parent_path.write_text(json.dumps({**f.parent, field:value}))
                with self.subTest(proof_field=field), self.assertRaises(ValueError):
                    LOCAL.parent_binding(dict(f.invocation, parent_OCI_proof_sha256=LOCAL.fingerprint(f.parent_path)), f.platform)
            f.parent_path.write_text(json.dumps(f.parent))
            index = Path(f.parent['context']) / 'index.json'
            original_index = index.read_text()
            index.write_text('changed Android index')
            with self.assertRaisesRegex(ValueError, 'OCI context differs'):
                LOCAL.parent_binding(f.invocation, f.platform)
            index.write_text(original_index)
            Path(f.android['parent_OCI_proof']).write_text('changed Media receipt')
            with self.assertRaisesRegex(ValueError, 'Media receipt changed'):
                LOCAL.parent_binding(f.invocation, f.platform)

    def test_nvidia_final_requires_bound_cuda_flags_and_real_systemd_environment(self) -> None:
        f = self.nvidia_fixture()
        with f.commands():
            LOCAL.command_binding(f.invocation, f.android, f.platform, f.parent_reference)
            for name in ('ONNX_PACKAGE', 'PYTORCH_EXTRA', 'RUNTIME_WHEELS_SOURCE', 'CROSS_NVIDIA_SBSA',
                         'CROSS_BUILD_PLATFORM', 'ENABLE_DEEPSTREAM', 'ENABLE_TENSORRT', 'ARTIFACT_CONTEXT_ROOT'):
                invalid = '=image' if name == 'RUNTIME_WHEELS_SOURCE' else '=other'
                command = [name + invalid if value.startswith(name + '=') else value for value in f.invocation['command']]
                with self.subTest(flag=name), self.assertRaisesRegex(ValueError, 'environment differs: ' + name):
                    LOCAL.command_binding(dict(f.invocation, command=command), f.android, f.platform, f.parent_reference)
            command = f.invocation['command'].copy()
            command.pop(command.index('ENABLE_NVIDIA=true') - 1)
            with self.assertRaisesRegex(ValueError, 'environment differs: ENABLE_NVIDIA'):
                LOCAL.command_binding(dict(f.invocation, command=command), f.android, f.platform, f.parent_reference)
            for variant_unit in (f.unit.replace('runtime-nvidia-', 'runtime-'), f.unit):
                command = [value.replace(f.unit, variant_unit) for value in f.invocation['command']]
                if variant_unit == f.unit:
                    command.insert(4, '--unit=' + variant_unit)
                with self.subTest(unit=variant_unit), self.assertRaisesRegex(ValueError, 'NVIDIA runtime unit differs'):
                    LOCAL.command_binding(dict(f.invocation, command=command, unit=variant_unit), f.android, f.platform, f.parent_reference)

    def test_nvidia_final_checks_native_android_driver_and_worker_closure(self) -> None:
        f = self.nvidia_fixture()
        with f.commands():
            LOCAL.host_binding(f.invocation)
            workers = {path:identity for path, identity in f.invocation['selected_host_workers_sha256'].items()
                       if not path.endswith('/nvidia_handoff_profile.py')}
            with self.assertRaisesRegex(ValueError, 'Runtime worker closure changed'):
                LOCAL.host_binding(dict(f.invocation, selected_host_workers_sha256=workers))
            command = [arg.replace('--image-repo', '--push') for arg in f.android['command']]
            with self.assertRaisesRegex(ValueError, 'Android driver differs'):
                LOCAL.android_input(dict(f.android, command=command), f.platform)
            with self.assertRaisesRegex(ValueError, 'stage image differs'):
                LOCAL.android_input(dict(f.android, image=f.android['image'].replace('-stages:', ':')), f.platform)

    def test_reference_and_object_text_inputs_reject_mutable_foreign_or_missing_values(self) -> None:
        for reference in ['ant-local/webgpu-fixture:latest', 'ghcr.io/owner/image@' + self.fixture.manifest,
                          'docker.io/other/image@' + self.fixture.manifest, 'docker.io/ant-local/webgpu-fixture@sha256:abc']:
            with self.subTest(reference=reference), self.assertRaises(ValueError):
                LOCAL.validate_reference(reference)
        for value in [None, '', 0, True, 'develop']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                LOCAL.text({'field':value}, 'field', LOCAL.SHA)
        with self.assertRaises(ValueError):
            LOCAL.text({}, 'missing')
        path = self.root / 'not-object.json'
        path.write_text('[]')
        with self.assertRaises(ValueError):
            LOCAL.read_object(path)

    def test_complete_plan_rejects_subset_reordering_argv_ref_timeout_and_extra_keys(self) -> None:
        original = self.fixture.contract
        changes = [dict(original, consumers=original['consumers'][:-1]),
                   dict(original, consumers=list(reversed(original['consumers']))),
                   dict(original, timeout_seconds=1), dict(original, extra='unreviewed')]
        for key, value in [('ref', 'other'), ('command', ['true'])]:
            changed = copy.deepcopy(original)
            changed['consumers'][0][key] = value
            changes.append(changed)
        for changed in changes:
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                LOCAL.complete_plan(changed, original)
            with self.subTest(startup=changed), self.assertRaisesRegex(ValueError, 'complete canonical'):
                MAIN.acceptance_transport(self.fixture.args, changed)
            self.assertEqual(self.fixture.calls, [])

    def test_forbidden_modes_are_refused_before_the_bound_driver(self) -> None:
        for flag in ['--push', '--gates-only']:
            invocation = copy.deepcopy(self.fixture.invocation)
            invocation['command'].insert(2, flag)
            with self.subTest(flag=flag), self.assertRaisesRegex(ValueError, 'Actual unpublished local runtime'):
                LOCAL.command_binding(invocation, self.fixture.android, self.fixture.platform, self.fixture.parent_reference)

    def test_local_mode_is_explicit_and_preserves_existing_outputs(self) -> None:
        self.fixture.args.local_runtime_invocation = None
        with self.assertRaises(ValueError):
            MAIN.acceptance_transport(self.fixture.args, self.fixture.contract)
        self.fixture.args.local_runtime_invocation = str(self.fixture.invocation_path)
        for location in [Path(self.fixture.args.workspace), Path(self.fixture.args.receipt)]:
            location.write_text('preserved evidence')
            with self.subTest(location=location), self.assertRaises(ValueError):
                MAIN.acceptance_transport(self.fixture.args, self.fixture.contract)
            self.assertEqual(location.read_text(), 'preserved evidence')
            location.unlink()

    def test_fresh_local_outputs_reject_dangling_symlink_entries(self) -> None:
        for selected in [Path(self.fixture.args.workspace), Path(self.fixture.args.receipt)]:
            def symbolic(path: Path, target: Path = selected) -> bool:
                return path == target
            with mock.patch.object(Path, 'exists', return_value=False), mock.patch.object(Path, 'is_symlink', new=symbolic), self.assertRaises(ValueError):
                MAIN.acceptance_transport(self.fixture.args, self.fixture.contract)

    def test_query_failure_preserves_status_stdout_and_stderr(self) -> None:
        self.fixture.engine_failure = 47
        with self.fixture.commands(), self.assertRaisesRegex(ValueError, '47.*query stdoutquery stderr'):
            LOCAL.output(['engine', 'images'])
        with self.fixture.commands(), self.assertRaises(ValueError):
            MAIN.check(self.fixture.args)
        receipt = json.loads(Path(self.fixture.args.receipt).read_text())
        self.assertEqual(receipt['status'], 'failed')
        self.assertIn('query stderr', receipt['error'])
        self.assertEqual(receipt['consumers'], [])

    def test_producer_scope_pin_and_source_flags_refuse_before_alias_or_consumers(self) -> None:
        fields = [('target_arch', 'arm64'), ('stage', 'media'), ('variant', 'other'), ('variant', {}),
                  ('launch_status', 47), ('launch_status', False), ('publication', True), ('unit', 'unrelated.service'),
                  ('output', str(self.root)), ('source_full_preflight_passed', False), ('producer_source_unchanged', False),
                  ('source_revision', 'develop'), ('source_full_preflight_sha256', 'e' * 64)]
        for key, value in fields:
            changed = dict(self.fixture.invocation, **{key:value})
            with self.fixture.commands(), self.subTest(key=key, value=value), self.assertRaises(ValueError):
                LOCAL.producer_inputs(changed, self.fixture.invocation_path, self.fixture.platform)
        with self.fixture.commands(), self.assertRaises(ValueError):
            LOCAL.producer_inputs(self.fixture.invocation, self.fixture.invocation_path, 'windows/amd64')
        for arch, variant in [('arm64', 'rocm'), ('riscv64', 'nvidia')]:
            directory = self.root / ('unsupported-' + arch)
            directory.mkdir()
            fixture = LocalFixture(directory, arch, variant)
            with fixture.commands(), self.assertRaises(ValueError):
                LOCAL.producer_inputs(fixture.invocation, fixture.invocation_path, 'linux/' + arch)
        self.assertFalse(any(command[:2] == ['engine', 'run'] for command in self.fixture.calls))

    def test_actual_source_and_terminal_apis_cannot_be_skipped_or_replaced_by_metadata(self) -> None:
        for target in [self.fixture.full_source, self.fixture.terminal]:
            target.side_effect = AssertionError('actual producer guard failed')
            with self.fixture.commands(), self.assertRaisesRegex(ValueError, 'actual producer guard failed'):
                LOCAL.producer_inputs(self.fixture.invocation, self.fixture.invocation_path, self.fixture.platform)
            target.side_effect = None
        for timestamp in ['', '0', 'invalid']:
            self.fixture.exit_timestamp = timestamp
            with self.fixture.commands(), self.assertRaises(ValueError):
                LOCAL.producer_inputs(self.fixture.invocation, self.fixture.invocation_path, self.fixture.platform)

    def test_host_binding_retains_clean_revision_complete_workers_and_wrapper_layout(self) -> None:
        with self.fixture.commands():
            LOCAL.host_binding(self.fixture.invocation)
            for head, dirty in [('e' * 40, ''), ('c' * 40, ' M source')]:
                self.fixture.host_head, self.fixture.host_dirty = head, dirty
                with self.assertRaises(ValueError):
                    LOCAL.host_binding(self.fixture.invocation)
            self.fixture.host_head, self.fixture.host_dirty = 'c' * 40, ''
            changed = dict(self.fixture.invocation, selected_host_workers_sha256={})
            with self.assertRaises(ValueError):
                LOCAL.host_binding(changed)
            wrong = self.fixture.host / 'linux/foreign/engine.py'
            wrong.parent.mkdir()
            wrong.write_text('synthetic')
            with self.assertRaises(ValueError):
                LOCAL.host_binding(dict(self.fixture.invocation, engine_wrapper=str(wrong)))
            wrong = self.fixture.host / 'linux/scripts/other.py'
            wrong.write_bytes(Path(self.fixture.invocation['engine_wrapper']).read_bytes())
            with self.assertRaises(ValueError):
                LOCAL.host_binding(dict(self.fixture.invocation, engine_wrapper=str(wrong)))
            path = self.fixture.workers[0]
            path.write_text(path.read_text() + '# changed\n')
            with self.assertRaises(ValueError):
                LOCAL.host_binding(self.fixture.invocation)

    def test_foreign_wrapper_requires_every_identical_companion_and_clean_source(self) -> None:
        directory = self.root / 'separate-wrapper/linux/scripts'
        directory.mkdir(parents=True)
        companions = [path for path in self.fixture.workers if path.parent == self.fixture.host / 'linux/scripts']
        for path in companions:
            shutil.copyfile(path, directory / path.name)
        changed = dict(self.fixture.invocation, engine_wrapper=str(directory / 'owned-nerdctl.py'))
        with self.fixture.commands():
            LOCAL.host_binding(changed)
            for path in companions:
                actual = directory / path.name
                original = actual.read_bytes()
                actual.write_bytes(original + b'# changed\n')
                with self.subTest(companion=path.name), self.assertRaisesRegex(ValueError, 'executed wrapper companion'):
                    LOCAL.host_binding(changed)
                actual.unlink()
                with self.assertRaises((ValueError, FileNotFoundError)):
                    LOCAL.host_binding(changed)
                actual.write_bytes(original)
            for root, label in [(self.fixture.host, 'host'), (directory.parents[1], 'wrapper')]:
                self.fixture.host_states[str(root)] = ('c' * 40, ' M source')
                with self.subTest(root=label), self.assertRaisesRegex(ValueError, label + ' source changed'):
                    LOCAL.host_binding(changed)
                self.fixture.host_states.clear()

    def test_worker_mapping_refuses_malformed_missing_ambiguous_and_relative_profiles(self) -> None:
        original = self.fixture.invocation['selected_host_workers_sha256']
        profile = str(self.fixture.host / 'linux/scripts/local-proof/runtime_launch_profile.py')
        for mapping in [[], {1:'x'}, {}, {**original, '/other/linux/scripts/local-proof/runtime_launch_profile.py':'x'},
                        {'relative/linux/scripts/local-proof/runtime_launch_profile.py':'x'}]:
            with self.fixture.commands(), self.subTest(mapping=mapping), self.assertRaises(ValueError):
                LOCAL.host_binding(dict(self.fixture.invocation, selected_host_workers_sha256=mapping))
        self.assertIn(profile, original)

    def test_parent_hash_source_lane_and_manifest_config_are_independent_bindings(self) -> None:
        for key in ['Android_invocation_sha256', 'parent_OCI_proof_sha256', 'parent_source_revision', 'parent_manifest', 'parent_config']:
            value = 'sha256:' + 'c' * 64 if key in ['parent_manifest', 'parent_config'] else 'c' * (40 if key == 'parent_source_revision' else 64)
            changed = dict(self.fixture.invocation, **{key:value})
            with self.subTest(key=key), self.assertRaises(ValueError):
                LOCAL.parent_binding(changed, self.fixture.platform)
        for key, value in [('stage', 'media'), ('target_arch', 'arm64'), ('variant', 'nvidia'), ('source_revision', 'c' * 40)]:
            data = dict(self.fixture.android, **{key:value})
            self.fixture.android_path.write_text(json.dumps(data))
            changed = dict(self.fixture.invocation, Android_invocation_sha256=LOCAL.fingerprint(self.fixture.android_path))
            with self.subTest(key=key), self.assertRaises(ValueError):
                LOCAL.parent_binding(changed, self.fixture.platform)
        self.fixture.android_path.write_text(json.dumps(self.fixture.android))

    def test_undeclared_android_requires_actual_source_and_preserves_original_bytes(self) -> None:
        self.fixture.command_android()
        original = self.fixture.android_path.read_bytes()
        with self.fixture.commands():
            normalized = LOCAL.android_input(self.fixture.android, self.fixture.platform)
            self.assertEqual(normalized['stage'], 'android')
            self.assertNotIn('stage', self.fixture.android)
            self.fixture.full_source.assert_called_once_with(self.fixture.source, self.fixture.full_proof, 'b' * 40)
            self.fixture.full_source.side_effect = AssertionError('synthetic complete-source refusal')
            with self.assertRaisesRegex(ValueError, 'synthetic complete-source refusal'):
                LOCAL.android_input(self.fixture.android, self.fixture.platform)
        self.assertEqual(self.fixture.android_path.read_bytes(), original)

    def test_undeclared_android_requires_valid_lane_launch_and_exact_source_evidence(self) -> None:
        self.fixture.command_android()
        for key, value in [('variant', None), ('variant', 'other'), ('unit', 'foreign.service'),
                           ('launch_status', True), ('launch_status', 1), ('publication', True),
                           ('source_full_preflight_passed', False), ('producer_source_unchanged', False),
                           ('source_full_preflight_sha256', '0' * 64), ('source_revision', 'invalid'),
                           ('command', None), ('command', [1])]:
            with self.fixture.commands(), self.subTest(key=key, value=value), self.assertRaises(ValueError):
                LOCAL.android_input({**self.fixture.android, key:value}, self.fixture.platform)

    def test_undeclared_android_full_driver_argv_and_variant_flag_cannot_change(self) -> None:
        self.fixture.command_android()
        original = self.fixture.android['command']
        changes = [original[:-1], ['foreign', *original[1:]], [*original, '--push'], [*original, '--gates-only'],
                   [value for value in original if value != '--expand-environment=no'],
                   [value for value in original if not value.startswith('--unit=')],
                   [value for value in original if not value.startswith('CROSS_VARIANT=')],
                   [*original[:4], 'CROSS_VARIANT=foreign', *original[5:]],
                   [*original[:4], 'CROSS_VARIANT=' + self.fixture.variant, *original[4:]],
                   [*original[:4], '--unit=foreign.service', *original[4:]],
                   [*original[:4], '--unit=' + self.fixture.android['unit'], *original[4:]]]
        for index in range(len(original) - 10, len(original)):
            changed = original.copy()
            changed[index] = 'foreign'
            changes.append(changed)
        for command in changes:
            with self.fixture.commands(), self.subTest(command=command), self.assertRaises(ValueError):
                LOCAL.android_input({**self.fixture.android, 'command':command}, self.fixture.platform)

    def test_runtime_driver_every_gate_vendor_and_original_android_pin_are_required(self) -> None:
        original = self.fixture.invocation['command']
        changes = [original[:-1], ['foreign', *original[1:]], [value for value in original if not value.startswith('--unit=')],
                   [value for value in original if value != '--expand-environment=no'], [*original, '--push'],
                   [value for value in original if not value.startswith('RUNTIME_ANDROID_PIN_')]]
        flags = [value for value in original if '=' in value and not value.startswith('--')]
        for flag in flags:
            changes.append([value if value != flag else flag.split('=', 1)[0] + '=foreign' for value in original])
            changes.append([flag, *original])
        for command in changes:
            changed = dict(self.fixture.invocation, command=command)
            with self.subTest(command=command), self.assertRaises(ValueError):
                LOCAL.command_binding(changed, self.fixture.android, self.fixture.platform, self.fixture.parent_reference)
        with self.assertRaises(ValueError):
            LOCAL.command_binding(dict(self.fixture.invocation, image=self.fixture.tag + '-package'), self.fixture.android,
                                  self.fixture.platform, self.fixture.parent_reference)
        for command in [None, [1]]:
            with self.assertRaises(ValueError):
                LOCAL.command_binding(dict(self.fixture.invocation, command=command), self.fixture.android,
                                      self.fixture.platform, self.fixture.parent_reference)

    def test_cleanup_requires_exact_ownership_success_and_independent_absence(self) -> None:
        for key, value in [('run_id', 'wrong'), ('expected_runtime_run_id', 'runtime-' + 'e' * 32), ('owner_label', 'org.other')]:
            with self.fixture.commands(), self.subTest(key=key), self.assertRaises(ValueError):
                LOCAL.cleanup_binding(dict(self.fixture.invocation, **{key:value}), self.fixture.directory, 'engine')
        for key, value in [('exit_status', 47), ('exit_status', False), ('run_id', 'e' * 32), ('owner_label', 'other')]:
            self.fixture.cleanup_path.write_text(json.dumps(dict(self.fixture.cleanup, **{key:value})))
            with self.fixture.commands(), self.assertRaises(ValueError):
                LOCAL.cleanup_binding(self.fixture.invocation, self.fixture.directory, 'engine')
        self.fixture.cleanup_path.write_text(json.dumps(self.fixture.cleanup))
        self.fixture.producer_present = True
        with self.fixture.commands(), self.assertRaisesRegex(ValueError, 'still owns containers'):
            LOCAL.cleanup_binding(self.fixture.invocation, self.fixture.directory, 'engine')

    def test_image_tag_digest_config_platform_and_every_final_label_are_checked(self) -> None:
        original_tag, original_digest = copy.deepcopy(self.fixture.tag_image), copy.deepcopy(self.fixture.digest_image)
        for key, value in [('Id', 'invalid'), ('RepoDigests', ['other@sha256:' + 'e' * 64]), ('Os', 'windows'), ('Architecture', 'arm64')]:
            self.fixture.tag_image = dict(original_tag, **{key:value})
            with self.fixture.commands(), self.subTest(key=key), self.assertRaises(ValueError):
                LOCAL.image_identity(self.fixture.invocation, self.fixture.reference, self.fixture.platform, self.fixture.parent_reference, 'engine')
        self.fixture.tag_image = copy.deepcopy(original_tag)
        for label in original_tag['Config']['Labels']:
            self.fixture.tag_image = copy.deepcopy(original_tag)
            self.fixture.tag_image['Config']['Labels'][label] = 'foreign'
            with self.fixture.commands(), self.subTest(label=label), self.assertRaises(ValueError):
                LOCAL.image_identity(self.fixture.invocation, self.fixture.reference, self.fixture.platform, self.fixture.parent_reference, 'engine')
        self.fixture.tag_image = copy.deepcopy(original_tag)
        for key, value in [('Id', 'sha256:' + 'e' * 64), ('RepoDigests', ['other@sha256:' + 'e' * 64])]:
            self.fixture.digest_image = dict(original_digest, **{key:value})
            with self.fixture.commands(), self.assertRaises(ValueError):
                LOCAL.image_identity(self.fixture.invocation, self.fixture.reference, self.fixture.platform, self.fixture.parent_reference, 'engine')
        self.fixture.digest_image = original_digest
        with self.fixture.commands(), self.assertRaises(ValueError):
            LOCAL.image_identity(self.fixture.invocation, self.fixture.reference.replace('webgpu-fixture', 'webgpu-other'),
                                 self.fixture.platform, self.fixture.parent_reference, 'engine')

    def test_observation_does_not_skip_required_producer_binding_failures(self) -> None:
        for name in ['producer_inputs', 'host_binding', 'parent_binding', 'command_binding', 'cleanup_binding', 'image_identity']:
            with self.fixture.commands(), mock.patch.object(LOCAL, name, side_effect=ValueError('required binding failed')) as guard, self.subTest(name=name), self.assertRaisesRegex(ValueError, 'required binding failed'):
                LOCAL.observe('engine', self.fixture.reference, self.fixture.platform, self.fixture.invocation_path)
            guard.assert_called_once()

    def test_prepare_observation_failure_precedes_alias_preparation(self) -> None:
        with self.fixture.commands(), mock.patch.object(LOCAL, 'observe', side_effect=ValueError('required observation')) as observed, \
                mock.patch.object(RUNTIME, 'prepare_local_alias') as alias, self.assertRaisesRegex(ValueError, 'required observation'):
            LOCAL.prepare('engine', self.fixture.reference, self.fixture.platform, str(self.fixture.invocation_path), self.root)
        observed.assert_called_once_with('engine', self.fixture.reference, self.fixture.platform, self.fixture.invocation_path)
        alias.assert_not_called()

    def test_existing_foreign_alias_is_never_overwritten(self) -> None:
        self.fixture.alias_ready = True
        self.fixture.alias_row['Digest'] = 'sha256:' + 'e' * 64
        with self.fixture.commands(), self.assertRaisesRegex(AssertionError, 'foreign existing alias'):
            LOCAL.prepare('engine', self.fixture.reference, self.fixture.platform, str(self.fixture.invocation_path), self.root)
        self.assertFalse(any(command[:3] == ['engine', 'image', 'tag'] for command in self.fixture.calls))

    def test_alias_readback_checks_count_digest_and_platform(self) -> None:
        valid = self.fixture.alias_row
        rows = [[], [valid, valid], [dict(valid, Digest='sha256:' + 'e' * 64)], [dict(valid, Platform='linux/arm64')]]
        for value in rows:
            with self.fixture.commands(), mock.patch.object(RUNTIME, 'alias_inventory', return_value=value), self.assertRaises(ValueError):
                LOCAL.verify_alias('engine', self.fixture.reference, self.fixture.platform,
                                   {'manifest':self.fixture.manifest, 'config':self.fixture.config, 'image':self.fixture.tag})

    def test_shared_alias_refuses_unsupported_platform_before_any_engine_operation(self) -> None:
        with self.fixture.commands(), self.assertRaisesRegex(AssertionError, 'Unsupported local alias platform'):
            RUNTIME.prepare_local_alias({'manifest':self.fixture.manifest, 'config':self.fixture.config, 'image':self.fixture.tag},
                                        self.root / 'unsupported-alias.json', platform='linux/s390x', engine='engine')
        self.assertEqual(self.fixture.calls, [])
        self.assertFalse((self.root / 'unsupported-alias.json').exists())

    def test_engine_image_records_must_be_one_object(self) -> None:
        for value in [[], [{}, {}], {}, None, ['wrong']]:
            with mock.patch.object(LOCAL, 'output', return_value=json.dumps(value)), self.assertRaises(ValueError):
                LOCAL.one_image('engine', self.fixture.reference)

    def test_cli_forwards_the_explicit_local_invocation_and_replay_paths(self) -> None:
        argv = ['image-acceptance.py', 'check', '--image', self.fixture.reference, '--engine', 'engine',
                '--plan', str(self.fixture.plan), '--workspace', self.fixture.args.workspace,
                '--receipt', self.fixture.args.receipt, '--local-runtime-invocation', str(self.fixture.invocation_path),
                '--replay', 'previous-local-receipt.json']
        with mock.patch.object(sys, 'argv', argv), mock.patch.object(MAIN, 'check') as checked:
            MAIN.main()
        args = checked.call_args.args[0]
        self.assertEqual(args.local_runtime_invocation, str(self.fixture.invocation_path))
        self.assertEqual(args.replay, 'previous-local-receipt.json')
        self.assertEqual(args.image, self.fixture.reference)
        self.assertEqual(args.engine, 'engine')

    def test_recheck_refuses_identity_evidence_changes_and_alias_drift(self) -> None:
        with self.fixture.commands():
            before = LOCAL.prepare('engine', self.fixture.reference, self.fixture.platform, str(self.fixture.invocation_path), self.root)
            self.fixture.alias_row['Platform'] = 'linux/arm64'
            with self.assertRaises(ValueError):
                LOCAL.recheck('engine', self.fixture.reference, self.fixture.platform, str(self.fixture.invocation_path), before)
            self.fixture.alias_row['Platform'] = self.fixture.platform
            self.fixture.cleanup_path.write_text(json.dumps({**self.fixture.cleanup, 'new_field':'changed evidence'}))
            with self.assertRaises(ValueError):
                LOCAL.recheck('engine', self.fixture.reference, self.fixture.platform, str(self.fixture.invocation_path), before)

    def test_failed_consumer_timeout_source_change_and_cleanup_keep_failed_receipts(self) -> None:
        cases = [('consumer_status', 37), ('consumer_timeout', True), ('dirty_consumer', True), ('consumer_present', True)]
        for index, (key, value) in enumerate(cases):
            directory = self.root / ('failure-' + str(index))
            directory.mkdir()
            fixture = LocalFixture(directory)
            setattr(fixture, key, value)
            with fixture.commands(), self.subTest(key=key), self.assertRaises(ValueError):
                MAIN.check(fixture.args)
            receipt = json.loads(Path(fixture.args.receipt).read_text())
            self.assertEqual(receipt['status'], 'failed')
            self.assertEqual(len(receipt['consumers']), 1)
            self.assertTrue((Path(fixture.args.workspace) / NAMES[0]).exists())
            self.assertIn('log_sha256', receipt['consumers'][0])
            self.assertTrue(any(command[:2] == ['engine', 'ps'] and any(value.startswith('name=') for value in command) for command in fixture.calls))

    def test_failed_postcheck_or_invalid_receipt_never_leaves_passed_evidence_or_prunes_sources(self) -> None:
        for index, stage in enumerate(['postcheck', 'receipt']):
            directory = self.root / ('post-' + str(index))
            directory.mkdir()
            fixture = LocalFixture(directory)
            target = mock.patch.object(LOCAL, 'recheck', side_effect=ValueError('changed identity')) if stage == 'postcheck' else \
                     mock.patch.object(MAIN, 'validate_consumer_result', side_effect=ValueError('invalid result'))
            with fixture.commands(), target, self.assertRaises(ValueError):
                MAIN.check(fixture.args)
            receipt = json.loads(Path(fixture.args.receipt).read_text())
            self.assertEqual(receipt['status'], 'failed')
            self.assertTrue((Path(fixture.args.workspace) / NAMES[0]).exists())

    def test_local_replay_keeps_all_original_source_bindings_and_checks_identity(self) -> None:
        first = self.passed_receipt()
        self.fixture.args.replay = self.fixture.args.receipt
        self.fixture.args.workspace = str(self.root / 'replay-sources')
        self.fixture.args.receipt = str(self.root / 'replay-receipt.json')
        with self.fixture.commands():
            MAIN.check(self.fixture.args)
        second = json.loads(Path(self.fixture.args.receipt).read_text())
        self.assertEqual(first['local_subject'], second['local_subject'])
        self.assertEqual(self.fixture.received_sources[6:], first['consumers'])
        self.assertEqual(first['consumers'][0]['resolved_locks'], second['consumers'][0]['resolved_locks'])
        self.assertEqual(len(second['consumers']), 6)

    def test_local_receipt_cannot_authorize_registry_publication_even_if_image_and_schema_are_rewritten(self) -> None:
        receipt = self.passed_receipt()
        for forged in ['original', 'reference', 'marker', 'local-data-removed']:
            value = copy.deepcopy(receipt)
            if forged != 'original':
                value.update(image='ghcr.io/owner/test@' + self.fixture.manifest, schema_version=1)
            if forged == 'marker':
                value['image_transport'] = 'registry'
            if forged == 'local-data-removed':
                value = {key:entry for key, entry in value.items() if not key.startswith('local_')}
            path = self.root / 'promotion.json'
            path.write_text(json.dumps(value))
            with mock.patch.object(MAIN, 'Registry', side_effect=AssertionError('must not reach registry')) as registry, self.assertRaises(ValueError):
                MAIN.promote(types.SimpleNamespace(receipt=path, plan=self.fixture.plan, target='ghcr.io/owner/test:latest'))
            registry.assert_not_called()

    def test_local_receipt_requires_complete_matching_before_after_and_exact_schema(self) -> None:
        receipt = self.passed_receipt()
        MAIN.validate_receipt(receipt, self.fixture.reference, self.fixture.plan, allow_local=True)
        for field, value in [('schema_version', 1), ('image_transport', 'registry'), ('local_subject_after', {}),
                             ('local_alias_sha256', 'wrong'), ('local_alias_receipt', '')]:
            changed = dict(receipt, **{field:value})
            with self.subTest(field=field), self.assertRaises(ValueError):
                MAIN.validate_receipt(changed, self.fixture.reference, self.fixture.plan, allow_local=True)
        for key in ['producer_invocation_sha256', 'runtime_proof_sha256', 'cleanup_sha256', 'original_Android_sha256', 'parent_proof_sha256',
                    'source_revision', 'parent_source_revision', 'host_tools_revision', 'config', 'parent_manifest', 'parent_config',
                    'runtime_run_id', 'producer_invocation', 'variant', 'kind', 'image', 'platform', 'exit_timestamp_monotonic']:
            changed = copy.deepcopy(receipt)
            value = 0 if key == 'exit_timestamp_monotonic' else 'wrong'
            changed['local_subject'][key] = changed['local_subject_after'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                MAIN.validate_receipt(changed, self.fixture.reference, self.fixture.plan, allow_local=True)
        for key, value in [('Id', 'foreign.service'), ('LoadState', 'not-found'), ('ActiveState', 'activating'),
                           ('SubState', 'start'), ('MainPID', '77'), ('ExecMainStatus', '1'), ('Result', 'exit-code')]:
            changed = copy.deepcopy(receipt)
            changed['local_subject']['unit'][key] = changed['local_subject_after']['unit'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                MAIN.validate_receipt(changed, self.fixture.reference, self.fixture.plan, allow_local=True)

    def test_local_validator_rejects_a_self_consistent_subset_receipt(self) -> None:
        receipt = self.passed_receipt()
        plan = self.root / 'subset-plan.json'
        subset = copy.deepcopy(self.fixture.contract)
        subset['consumers'] = subset['consumers'][:1]
        plan.write_text(json.dumps(subset))
        receipt['consumers'] = receipt['consumers'][:1]
        receipt['plan_sha256'] = MAIN.fingerprint(plan)
        with self.assertRaisesRegex(ValueError, 'complete canonical'):
            MAIN.validate_receipt(receipt, self.fixture.reference, plan, allow_local=True)

    def test_malformed_label_objects_and_receipt_unit_types_are_refused(self) -> None:
        for config in [None, {}, {'Labels':None}, {'Labels':[]}]:
            self.fixture.tag_image['Config'] = config
            with self.fixture.commands(), self.assertRaises(ValueError):
                LOCAL.image_identity(self.fixture.invocation, self.fixture.reference, self.fixture.platform,
                                     self.fixture.parent_reference, 'engine')
        self.fixture.make_image()
        receipt = self.passed_receipt()
        for unit in [None, [], 'not a unit']:
            changed = copy.deepcopy(receipt)
            changed['local_subject']['unit'] = changed['local_subject_after']['unit'] = unit
            with self.assertRaises(ValueError):
                MAIN.validate_receipt(changed, self.fixture.reference, self.fixture.plan, allow_local=True)
        changed = copy.deepcopy(receipt)
        changed['local_subject']['exit_timestamp_monotonic'] = changed['local_subject_after']['exit_timestamp_monotonic'] = True
        with self.assertRaises(ValueError):
            MAIN.validate_receipt(changed, self.fixture.reference, self.fixture.plan, allow_local=True)

    def test_companion_loading_refuses_foreign_warm_modules_or_missing_companions(self) -> None:
        for loader in [MAIN.local_module, lambda: LOCAL.local_api('runtime_launch_profile')]:
            for filename in [None, str(self.root / 'foreign.py')]:
                foreign = types.ModuleType('foreign')
                foreign.__file__ = filename
                with mock.patch.object(sys, 'path', sys.path.copy()), mock.patch.object(MAIN.importlib, 'import_module', return_value=foreign), self.assertRaises(ValueError):
                    loader()
            with mock.patch.object(sys, 'path', sys.path.copy()), mock.patch.object(MAIN.importlib, 'import_module', side_effect=ModuleNotFoundError('missing')), self.assertRaises(ModuleNotFoundError):
                loader()


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0], *sys.argv[1:]])
