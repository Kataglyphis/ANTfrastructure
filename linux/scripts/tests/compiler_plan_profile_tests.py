"""Synthetic source files and explicit Git/manager doubles grade planner boundaries, not provenance, builds or cache hits."""

import contextlib
import copy
import hashlib
import io
import json
import runpy
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
TOOLS = ROOT / 'linux/scripts/local-proof'
sys.path.insert(0, str(TOOLS))
PROFILE = runpy.run_path(str(TOOLS / 'compiler_plan_profile.py'))
CONTEXT = 'linux/scripts/01-core/context-management.sh'
CONTROLS = (CONTEXT, 'linux/scripts/build-cross-stage.sh', 'linux/scripts/lib-orchestrator.sh',
            'linux/scripts/01-core/cross-stage-build.sh', 'linux/scripts/01-core/chain-storage.sh')
LLVM = ('linux/scripts/02-toolchain/llvm.sh', 'linux/scripts/02-toolchain/llvm-cross.sh',
        'linux/scripts/02-toolchain/materialize-llvm-target.sh')
LEGACY = '10ff1924998a38a0f0f47f1ace4f7d86661fc028d87c4de900ba1fae0d3b4df1'
PIN = '8271db71f46ab74393ff45c14864d0eaca6707a5'


class CompilerPlanFixture(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix='compiler plan profile ')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / 'current source'
        self.previous = self.root / 'prior source'
        self.inputs = self.root / 'inputs'
        self.inputs.mkdir()
        self.head = 'b' * 40
        self.transport = b'independent reviewed OCI transport fixture\n'
        self.ancestry = True
        self.manager = ''
        self.number = 0
        self.make_source()
        self.accepted_materializer = (self.source / LLVM[2]).read_bytes()
        self.make_records()

    def write(self, relative: str, data: bytes) -> None:
        target = self.source / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)

    def fingerprint(self, name: str) -> dict[str, Any]:
        data = (self.source / name).read_bytes()
        return {'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data)}

    def make_source(self) -> None:
        for name in (*CONTROLS, *LLVM, 'linux/scripts/06-packaging/smoke-toolchain.sh'):
            self.write(name, ('independent current fixture ' + name).encode())
        self.write(CONTEXT, self.transport)
        self.dockerfile = ('FROM fixture\nRUN --mount=type=bind,source=linux/scripts/01-core/chain-storage.sh,target=/core true\n\n'
                           'RUN true\n\n')
        self.write('linux/Dockerfile.toolchain', self.dockerfile.encode())
        (self.previous / 'linux').mkdir(parents=True)
        (self.previous / 'linux/Dockerfile.toolchain').write_text(self.dockerfile)
        self.write('docs/scripts/mutations.json', b'[{"id":"fixture.only"}]\n')

    def make_records(self) -> None:
        self.audit: dict[str, Any] = {'files_sha256': {name:self.fingerprint(name)['sha256'] for name in CONTROLS},
                                      'manager_keys_unset':['UNREVIEWED_STORAGE_FLAG']}
        self.audit['files_sha256'][CONTEXT] = LEGACY
        self.old_inputs = {name:self.fingerprint(name) for name in (*CONTROLS, *LLVM)}
        for name in LLVM:
            self.old_inputs[name] = {'sha256': 'a' * 64, 'size': 1}
        self.old_inputs[CONTEXT] = {'sha256':LEGACY, 'size':42}
        self.template: dict[str, Any] = {'required_bytes':193273528320, 'local_image':'ant-local/old:cross-compiler-amd64',
                         'source':str(self.previous), 'output':'/prior output', 'source_revision':'a' * 40,
                         'unit':'webgpu-normal-compiler-old.service', 'storage_path_audit':'audit.json',
                         'expensive_inputs_proof':str(self.inputs / 'expensive.json'),
                         'base_manifest':'sha256:' + '1' * 64, 'base_config':'sha256:' + '2' * 64,
                         'base_oci_index_sha256':'3' * 64, 'expected_pins':{'GCC_VERSION':'fixture'},
                         'command':['systemd-run', '--unit=webgpu-normal-compiler-old.service',
                                    str(self.previous / 'linux/scripts/build-cross-stage.sh'),
                                    '--image-repo', 'ant-local/old', '--log-dir', '/prior output/logs']}
        self.targeted = {'status':'passed-targeted-source-native-Clang-wrapper-and-backend-repair-only',
                         'owner_source':str(self.source), 'quality_group_count':26, 'cleanup_exit_status':0,
                         'independent_engine_query_exit_status':0, 'owned_container_absent':True, 'patch_sha256':'4' * 64}
        self.commit = {'head':self.head, 'source':str(self.source), 'normal_hook_status':0, 'actual_hook_mutations':16,
                       'exact_committed_patch_match':True, 'clean':True, 'patch_sha256':'4' * 64,
                       'status':'passed-local-source-commit-normal-hooks-only'}

    def git_and_manager(self, command: list[str], **kwargs: object) -> str | bytes:
        if command == ['systemctl', '--user', 'show-environment']:
            value = self.manager.encode()
        else:
            self.assertEqual(command[:3], ['git', '-C', str(self.source)])
            args = command[3:]
            if args == ['rev-parse', 'HEAD']:
                value = (self.head + '\n').encode()
            elif args == ['status', '--porcelain']:
                value = b''
            elif args == ['merge-base', '--is-ancestor', PIN, 'HEAD']:
                if not self.ancestry:
                    raise subprocess.CalledProcessError(1, command)
                value = b''
            elif args == ['show', PIN + ':' + CONTEXT]:
                value = self.transport
            elif args == ['show', 'e7ca4436dbb5e58d8f9e0fb49105b6d3b636e9e9:' + LLVM[2]]:
                value = self.accepted_materializer
            else:
                raise AssertionError('Unexpected fixture command: ' + repr(command))
        return value.decode() if kwargs.get('text') else value

    def plan(self, profile: str | None = 'native-amdgpu') -> tuple[dict[str, Any], Path]:
        self.number += 1
        output = self.root / ('result ' + str(self.number))
        output.mkdir()
        for name, record in [('template', self.template), ('audit', self.audit),
                             ('expensive', {'unchanged_bind_files':self.old_inputs}),
                             ('targeted', self.targeted), ('commit', self.commit)]:
            (self.inputs / (name + '.json')).write_text(json.dumps(record))
        argv = [str(TOOLS / 'prepare-next-compiler-plan.py'), '--source', str(self.source),
                '--template', str(self.inputs / 'template.json'), '--targeted-proof', str(self.inputs / 'targeted.json'),
                '--commit-proof', str(self.inputs / 'commit.json'), '--output', str(output / 'plan.json'),
                '--unit', 'webgpu-normal-compiler-fixture.service', '--image-repo', 'ant-local/new']
        if profile is not None:
            argv += ['--profile', profile]
        with mock.patch.object(sys, 'argv', argv), mock.patch('subprocess.check_output', side_effect=self.git_and_manager), contextlib.redirect_stdout(io.StringIO()):
            runpy.run_path(str(TOOLS / 'prepare-next-compiler-plan.py'), run_name='__main__')
        return json.loads((output / 'plan.json').read_text()), output

    def differences(self) -> dict[str, Any]:
        return {name:{'previous':copy.deepcopy(self.old_inputs[name]), 'current':self.fingerprint(name)}
                for name in (*LLVM, CONTEXT)}

    def review(self) -> dict[str, Any]:
        return {'commit':PIN, 'sha256':hashlib.sha256(self.transport).hexdigest(), 'size':len(self.transport)}


class CompilerPlanProfileTests(CompilerPlanFixture):
    def test_native_profile_preserves_all_deltas_and_reports_actual_control_change(self) -> None:
        plan, output = self.plan()
        audit = json.loads((output / 'compiler-storage-path-audit.json').read_text())
        comparison = json.loads((output / 'build-inputs-comparison.json').read_text())
        self.assertEqual(plan['planner_profile'], 'native-amdgpu')
        self.assertFalse(audit['source_control_files_equal_previous_audit'])
        self.assertEqual(set(audit['reviewed_control_changes']), {CONTEXT})
        self.assertEqual(audit['reviewed_control_changes'][CONTEXT]['previous'], LEGACY)
        self.assertEqual(audit['files_sha256'][CONTEXT], self.fingerprint(CONTEXT)['sha256'])
        self.assertEqual(set(comparison['changed_bound_files']), {*LLVM, CONTEXT})
        self.assertNotIn(CONTEXT, comparison['unchanged_bound_files'])
        self.assertEqual(comparison['reviewed_OCI_transport'], self.review())
        self.assertTrue(comparison['GNU_mounts_unchanged'])
        self.assertFalse(comparison['cache_hits_claimed'])
        self.assertFalse(plan['publication'])
        self.assertEqual(plan['required_bytes'], 193273528320)
        self.assertEqual(plan['command'][-1], str(output / 'compiler-rebuild-1/logs'))
        self.assertEqual(plan['base_manifest'], self.template['base_manifest'])

    def test_default_legacy_profile_keeps_three_deltas_and_unchanged_control_verdict(self) -> None:
        self.ancestry = False
        self.audit['files_sha256'][CONTEXT] = self.fingerprint(CONTEXT)['sha256']
        self.old_inputs[CONTEXT] = self.fingerprint(CONTEXT)
        plan, output = self.plan(None)
        comparison = json.loads((output / 'build-inputs-comparison.json').read_text())
        self.assertEqual(plan['planner_profile'], 'clang-wrapper-repair')
        self.assertEqual(set(comparison['changed_bound_files']), set(LLVM))
        self.assertIsNone(comparison['reviewed_OCI_transport'])
        self.assertEqual(comparison['status'], 'reviewed-GNU-closure-equal-LLVM-closure-intentionally-changed-only')
        self.assertTrue(json.loads((output / 'compiler-storage-path-audit.json').read_text())['source_control_files_equal_previous_audit'])

    def test_legacy_profile_refuses_the_fourth_transport_delta(self) -> None:
        self.audit['files_sha256'][CONTEXT] = self.fingerprint(CONTEXT)['sha256']
        with self.assertRaises(AssertionError):
            self.plan('clang-wrapper-repair')

    def test_planner_rejects_extra_input_outside_storage_controls(self) -> None:
        self.write('unreviewed.sh', b'new bytes')
        self.old_inputs['unreviewed.sh'] = {'sha256':'a' * 64, 'size':1}
        with self.assertRaisesRegex(AssertionError, 'reviewed profile'):
            self.plan()

    def test_planner_rejects_storage_change_even_when_reference_calls_it_unchanged(self) -> None:
        name = 'linux/scripts/lib-orchestrator.sh'
        self.write(name, b'unreviewed current control')
        self.old_inputs[name] = self.fingerprint(name)
        with self.assertRaisesRegex(AssertionError, 'storage-control'):
            self.plan()

    def test_transport_requires_pinned_history_and_exact_current_bytes(self) -> None:
        self.ancestry = False
        with self.assertRaises(subprocess.CalledProcessError):
            self.plan()
        self.ancestry = True
        self.write(CONTEXT, b'unreviewed transport bytes')
        with mock.patch('subprocess.check_output', side_effect=self.git_and_manager), self.assertRaisesRegex(AssertionError, 'reviewed commit'):
            PROFILE['reviewed_transport'](self.source, 'native-amdgpu')

    def test_storage_audit_requires_every_control(self) -> None:
        previous = {name:self.fingerprint(name)['sha256'] for name in CONTROLS}
        previous.pop('linux/scripts/lib-orchestrator.sh')
        with self.assertRaisesRegex(AssertionError, 'five controls'):
            PROFILE['storage_changes'](self.source, previous, None)

    def test_storage_audit_refuses_unknown_prior_transport(self) -> None:
        previous = dict(self.audit['files_sha256'])
        previous[CONTEXT] = 'c' * 64
        with self.assertRaisesRegex(AssertionError, 'control baseline'):
            PROFILE['storage_changes'](self.source, previous, self.review())

    def test_native_input_scope_requires_exact_four_paths_and_approved_fingerprint(self) -> None:
        original = self.differences()
        for mutate in [lambda data:data.pop(CONTEXT), lambda data:data.update({'extra.sh':data[CONTEXT]}),
                       lambda data:data[CONTEXT]['previous'].update(sha256='c' * 64),
                       lambda data:data[CONTEXT]['current'].update(sha256='c' * 64),
                       lambda data:data[CONTEXT]['current'].update(size=1)]:
            data = copy.deepcopy(original)
            mutate(data)
            with self.assertRaises(AssertionError):
                PROFILE['validate_input_changes'](data, 'native-amdgpu', self.review())
        with self.assertRaises(AssertionError):
            PROFILE['validate_input_changes'](original, 'native-amdgpu', None)

    def test_unknown_module_profile_is_never_treated_as_native(self) -> None:
        with mock.patch('subprocess.check_output', side_effect=self.git_and_manager), self.assertRaises(AssertionError):
            PROFILE['reviewed_transport'](self.source, 'unknown')
        with self.assertRaises(AssertionError):
            PROFILE['validate_input_changes'](self.differences(), 'unknown', self.review())
        narrow = self.differences()
        narrow.pop(CONTEXT)
        with self.assertRaises(AssertionError):
            PROFILE['validate_input_changes'](narrow, 'unknown', None)

    def test_changed_transport_is_never_an_unchanged_GNU_mount(self) -> None:
        docker = self.dockerfile.replace('linux/scripts/01-core/chain-storage.sh', CONTEXT)
        self.write('linux/Dockerfile.toolchain', docker.encode())
        (self.previous / 'linux/Dockerfile.toolchain').write_text(docker)
        with self.assertRaises(AssertionError):
            self.plan()

    def test_Dockerfile_and_manager_storage_flags_remain_guarded(self) -> None:
        self.write('linux/Dockerfile.toolchain', (self.dockerfile + '# drift\n').encode())
        with self.assertRaises(AssertionError):
            self.plan()
        self.write('linux/Dockerfile.toolchain', self.dockerfile.encode())
        self.manager = 'UNREVIEWED_STORAGE_FLAG=1\n'
        with self.assertRaises(AssertionError):
            self.plan()

    def test_reviewed_materializer_bytes_do_not_follow_current_file_drift(self) -> None:
        path = self.source / LLVM[2]
        path.write_bytes(path.read_bytes() + b'changed')
        with self.assertRaisesRegex(AssertionError,'Materializer differs'):
            self.plan()

    def test_profiles_preserve_push_and_reserve_refusals(self) -> None:
        self.template['command'].insert(1, '--push')
        with self.assertRaises(AssertionError):
            self.plan()
        self.template['command'].remove('--push')
        self.template['required_bytes'] = 1
        with self.assertRaises(AssertionError):
            self.plan()


if __name__ == '__main__':
    unittest.main()
