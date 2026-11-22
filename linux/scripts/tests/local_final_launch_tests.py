"""Synthetic bounded FINAL lifecycle and real receipt-schema controls; no real consumers, reclamation, licence closure or GPU inference."""

from __future__ import annotations

import copy
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

from image_acceptance_local_fixture import LOCAL, MAIN, NAMES, LocalFixture

SPEC = importlib.util.spec_from_file_location('bounded_local_final', Path(__file__).resolve().parents[1] / 'launch-local-final.py')
assert SPEC is not None and SPEC.loader is not None
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)
ORIGINAL_WORKERS = M.workers


class FinalLaunchTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix='bounded-final-tests-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        fixture_root = self.root / 'existing'
        fixture_root.mkdir()
        self.fixture = LocalFixture(fixture_root)
        with self.fixture.commands():
            MAIN.check(self.fixture.args)
        self.receipt = json.loads(Path(self.fixture.args.receipt).read_text())
        self.origin = self.receipt['local_subject']
        self.home = self.root / 'home'
        (self.home / '.cache').mkdir(parents=True)
        self.directory = self.root / 'bounded'
        self.unit = 'webgpu-local-final-amd64-999-1.service'
        self.code = self.root / 'worker.py'
        self.code.write_text('# synthetic worker identity\n')
        self.head, self.dirty = 'c' * 40, ''
        self.state = {'Id':self.unit, 'LoadState':'not-found', 'ActiveState':'inactive', 'SubState':'dead',
                      'MainPID':'0', 'Result':'success', 'ExecMainStatus':'0', 'ExecMainExitTimestampMonotonic':'0'}
        self.after_state = {'ActiveState':'inactive', 'SubState':'dead', 'MainPID':'0', 'Result':'success'}
        self.calls: list[list[str]] = []
        self.options: list[dict[str, Any]] = []
        self.check_args: list[Any] = []
        self.launch_status = self.query_status = 0
        self.query_output, self.query_error = '', 'query diagnostic'
        self.observe = mock.Mock(return_value=(self.origin, {}))
        self.recheck = mock.Mock(return_value=self.origin)
        self.local = types.SimpleNamespace(complete_plan=LOCAL.complete_plan, observe=self.observe, recheck=self.recheck, local_api=LOCAL.local_api)
        self.ids = mock.Mock(return_value=set())
        self.inner_error: Exception | None = None
        patches = [mock.patch.dict(M.os.environ, {}), mock.patch.object(M, 'ENGINE', '/fixture/nerdctl'),
                   mock.patch.object(M, 'workers', return_value=[self.code]), mock.patch.object(Path, 'home', return_value=self.home),
                   mock.patch.object(M, 'checked_output', side_effect=self.checked), mock.patch.object(M, 'UNIT_STATE', side_effect=self.unit_state),
                   mock.patch.object(M.subprocess, 'run', side_effect=self.run_command), mock.patch.object(M.os, 'getpid', return_value=73),
                   mock.patch.object(M.OwnedContainers, 'ids', self.ids),
                   mock.patch.dict(M.API, {'local_module':lambda:self.local, 'check':self.check})]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def checked(self, command: list[str], **options: Any) -> str:
        self.calls.append(command)
        if command[:1] == ['git']:
            return self.head if command[-1] == 'HEAD' else self.dirty
        if command[:3] == ['systemctl', '--user', 'stop']:
            self.state.update(self.after_state)
            path = self.directory / 'cleanup.json'
            if not path.exists():
                record = M.read(self.directory / 'invocation.json')
                M.save(path, {'exit_status':0, 'owner_label':M.OWNER, 'run_id':record['run_id']})
            return ''
        raise AssertionError('Unexpected real command: ' + repr(command))

    def unit_state(self, unit: str) -> dict[str, str]:
        self.assertEqual(unit, self.unit)
        return dict(self.state)

    def run_command(self, command: list[str], **options: Any) -> subprocess.CompletedProcess[str]:
        self.calls.append(command)
        self.options.append(options)
        if command[0] == 'systemd-run':
            return subprocess.CompletedProcess(command, self.launch_status, 'launch stdout', 'launch stderr')
        if command[:3] == ['/fixture/nerdctl', 'ps', '-a']:
            return subprocess.CompletedProcess(command, self.query_status, self.query_output, self.query_error)
        raise AssertionError('Unexpected subprocess: ' + repr(command))

    def check(self, args: Any) -> None:
        self.check_args.append(args)
        if self.inner_error is not None:
            raise self.inner_error
        receipt = copy.deepcopy(self.receipt)
        receipt['plan_sha256'] = M.fingerprint(Path(args.plan))
        receipt['hub_revision'] = self.head
        M.save(Path(args.receipt), receipt)

    def launch(self) -> dict[str, Any]:
        M.launch(self.fixture.invocation_path, self.fixture.reference, self.directory, self.unit)
        return M.read(self.directory / 'invocation.json')

    def live_worker(self) -> dict[str, Any]:
        record = self.launch()
        self.state.update(LoadState='loaded', ActiveState='activating', SubState='start', MainPID='73')
        M.os.environ.update(ANT_RUNTIME_ENGINE=M.ENGINE, ANT_RUNTIME_OWNER_LABEL=M.OWNER, ANT_RUNTIME_RUN_ID=record['run_id'])
        return record

    def finished(self) -> dict[str, Any]:
        record = self.live_worker()
        M.worker(self.directory)
        self.state.update(ActiveState='active', SubState='exited', MainPID='0', ExecMainExitTimestampMonotonic='7')
        return record

    def test_launch_freezes_full_plan_and_installs_owned_cleanup_before_worker(self) -> None:
        record = self.launch()
        command = record['command']
        for expected in ['--no-block', '--expand-environment=no', 'Type=oneshot', 'RemainAfterExit=yes',
                         'TimeoutStartSec=21600', 'TimeoutStopSec=300', 'KillMode=control-group',
                         'LC_ALL=C', 'ANT_RUNTIME_ENGINE=/fixture/nerdctl', 'ANT_RUNTIME_OWNER_LABEL=' + M.OWNER,
                         'ANT_RUNTIME_RUN_ID=' + record['run_id'], 'TMPDIR=' + str(self.home / '.cache' / self.unit.removesuffix('.service'))]:
            self.assertIn(expected, command)
        self.assertEqual(command[-3:], ['worker', '--directory', str(self.directory)])
        cleanup = record['cleanup_command']
        self.assertEqual(cleanup[cleanup.index('--cidfile') + 1], str(self.directory / 'container.cid'))
        self.assertEqual(cleanup[cleanup.index('--run-id') + 1], record['run_id'])
        self.assertTrue(any(value.startswith('ExecStopPost=') and 'cleanup-owned-containers.py' in value for value in command))
        self.assertEqual(M.read(self.directory / 'plan.json'), self.fixture.contract)
        self.assertEqual(record['local_subject'], self.origin)
        self.observe.assert_called_once_with(M.ENGINE, self.fixture.reference, 'linux/amd64', self.fixture.invocation_path)
        self.assertEqual(M.read(self.directory / 'launch-result.json')['stderr'], 'launch stderr')

    def test_launch_refuses_existing_paths_units_and_symlinks(self) -> None:
        self.directory.mkdir()
        with self.assertRaises(ValueError):
            self.launch()
        self.directory.rmdir()
        self.directory.symlink_to(self.root / 'absent')
        with self.assertRaises(ValueError):
            self.launch()
        self.directory.unlink()
        self.state['LoadState'] = 'loaded'
        with self.assertRaises(ValueError):
            self.launch()
        self.assertFalse(self.directory.exists())

    def test_launch_rejects_foreign_unit_architecture_and_dirty_source_early(self) -> None:
        for unit in ['foreign.service', 'webgpu-local-final-arm64-999-1.service']:
            with self.assertRaises(ValueError):
                M.launch(self.fixture.invocation_path, self.fixture.reference, self.directory, unit)
        self.fixture.invocation['target_arch'] = 'mips'
        self.fixture.save()
        with self.assertRaises(ValueError):
            self.launch()
        self.fixture.invocation['target_arch'] = 'amd64'
        self.fixture.save()
        self.dirty = ' M tracked'
        with self.assertRaises(ValueError):
            self.launch()
        self.assertFalse(self.directory.exists())

    def test_missing_producer_or_colliding_token_cannot_allocate_output(self) -> None:
        self.observe.side_effect = ValueError('Synthetic failed producer')
        with self.assertRaises(ValueError):
            self.launch()
        self.observe.side_effect = None
        self.ids.return_value = {'a' * 64}
        with self.assertRaises(ValueError):
            self.launch()
        self.assertFalse(self.directory.exists())

    def test_existing_temporary_directory_is_refused(self) -> None:
        (self.home / '.cache' / self.unit.removesuffix('.service')).mkdir()
        with self.assertRaises(ValueError):
            self.launch()
        self.assertFalse(self.directory.exists())

    def test_git_ancestor_of_temporary_directory_is_refused(self) -> None:
        (self.home / '.git').mkdir()
        with self.assertRaises(ValueError):
            self.launch()
        self.assertFalse(self.directory.exists())

    def test_launch_failure_retains_raw_both_streams(self) -> None:
        self.launch_status = 71
        with self.assertRaises(ValueError):
            self.launch()
        result = M.read(self.directory / 'launch-result.json')
        self.assertEqual(result, {'exit_status':71, 'stdout':'launch stdout', 'stderr':'launch stderr'})

    def test_binding_rejects_each_changed_identity_and_deadline_profile(self) -> None:
        original = self.launch()
        changes = [('source','/foreign'), ('engine','/foreign/nerdctl'), ('owner_label','org.kataglyphis.other'),
                   ('run_id','bad'), ('unit','foreign.service'), ('workers_sha256',{}), ('runtime_invocation_sha256','0' * 64),
                   ('plan_sha256','0' * 64), ('platform','linux/arm64'), ('timeout_seconds',False), ('timeout_seconds',21601)]
        for key, value in changes:
            record = {**original, key:value}
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                M.binding(self.directory, record)
        self.head = 'd' * 40
        with self.assertRaises(ValueError):
            M.binding(self.directory, original)

    def test_bound_plan_still_rejects_a_removed_consumer(self) -> None:
        record = self.launch()
        plan = M.read(self.directory / 'plan.json')
        plan['consumers'].pop()
        (self.directory / 'plan.json').write_text(json.dumps(plan))
        record['plan_sha256'] = M.fingerprint(self.directory / 'plan.json')
        with self.assertRaises(ValueError):
            M.binding(self.directory, record)

    def test_worker_uses_real_complete_receipt_schema_and_owned_engine(self) -> None:
        record = self.live_worker()
        M.worker(self.directory)
        self.assertEqual(len(self.check_args), 1)
        args = self.check_args[0]
        self.assertEqual(args.engine, str(M.HERE / 'owned-nerdctl.py'))
        self.assertEqual(args.local_runtime_invocation, str(self.fixture.invocation_path))
        self.assertEqual(args.image, self.fixture.reference)
        self.assertEqual(args.workspace, str(self.directory / 'consumers'))
        self.assertIsNone(args.replay)
        result = M.read(self.directory / 'worker-result.json')
        self.assertEqual(result['consumer_names'], NAMES)
        self.assertEqual(result['status'], 'completed-consumers-cleanup-pending')
        self.assertEqual(result['receipt_sha256'], M.fingerprint(self.directory / 'receipt.json'))
        self.assertFalse((self.directory / 'proof-stopped.json').exists())
        self.assertEqual(record['revision'], 'c' * 40)

    def test_worker_refuses_unbounded_pid_or_changed_environment_before_consumers(self) -> None:
        self.live_worker()
        self.state['MainPID'] = '74'
        with self.assertRaises(ValueError):
            M.worker(self.directory)
        self.state['MainPID'] = '73'
        M.os.environ['ANT_RUNTIME_RUN_ID'] = '0' * 32
        with self.assertRaises(ValueError):
            M.worker(self.directory)
        self.assertFalse(self.check_args)

    def test_worker_rechecks_producer_and_propagates_inner_failure(self) -> None:
        self.live_worker()
        self.observe.return_value = ({'changed':True}, {})
        with self.assertRaises(ValueError):
            M.worker(self.directory)
        self.observe.return_value = (self.origin, {})
        self.inner_error = ValueError('Synthetic consumer failure')
        with self.assertRaisesRegex(ValueError, 'Synthetic consumer failure'):
            M.worker(self.directory)
        self.assertFalse((self.directory / 'worker-result.json').exists())

    def test_worker_rejects_inner_receipt_with_foreign_hub(self) -> None:
        self.live_worker()
        self.receipt['hub_revision'] = 'd' * 40
        with mock.patch.dict(M.API, {'check':lambda args:M.save(Path(args.receipt), {**self.receipt, 'plan_sha256':M.fingerprint(Path(args.plan))})}), self.assertRaises(ValueError):
            M.worker(self.directory)

    def test_seal_checks_real_receipt_cleanup_and_independent_absence(self) -> None:
        record = self.finished()
        self.assertEqual(M.seal(self.directory), 0)
        proof = M.read(self.directory / 'proof-stopped.json')
        self.assertEqual(proof['status'], 'passed-bounded-local-final-consumers')
        self.assertEqual(proof['terminal']['ExecMainStatus'], '0')
        self.assertEqual(proof['stopped']['MainPID'], '0')
        self.assertTrue(proof['owned_containers_absent'])
        self.assertFalse(proof['registry_promotion'])
        self.assertFalse(proof['GPU_inference_proved'])
        self.recheck.assert_called_once()
        query = M.read(self.directory / 'independent-engine-query.json')
        self.assertEqual(query, {'returncode':0, 'stdout':'', 'stderr':'query diagnostic'})
        self.assertIn('label=' + M.OWNER + '=' + record['run_id'], self.calls[-1])
        self.state.update(ActiveState='active', SubState='exited', MainPID='0', LoadState='loaded')
        with self.assertRaises(ValueError):
            M.seal(self.directory)

    def test_failed_outer_unit_stays_failed_even_if_inner_receipt_passed(self) -> None:
        self.finished()
        self.state.update(ActiveState='failed', SubState='failed', Result='exit-code', ExecMainStatus='1')
        self.assertEqual(M.seal(self.directory), 1)
        self.assertEqual(M.read(self.directory / 'proof-stopped.json')['status'], 'failed-bounded-local-final-preserved')

    def test_seal_refuses_live_cached_or_inconsistent_raw_results(self) -> None:
        self.finished()
        original = dict(self.state)
        for change in [{'MainPID':'73'}, {'ExecMainExitTimestampMonotonic':'0'}, {'LoadState':'not-found'},
                       {'Id':'foreign.service'}, {'ExecMainStatus':'1'}, {'Result':'exit-code'}]:
            self.state = {**original, **change}
            with self.subTest(change=change), self.assertRaises(ValueError):
                M.seal(self.directory)
        self.assertFalse(any(row[:3] == ['systemctl', '--user', 'stop'] for row in self.calls))

    def test_seal_refuses_changed_worker_result_receipt_and_order(self) -> None:
        self.finished()
        result_path = self.directory / 'worker-result.json'
        original = M.read(result_path)
        for change in [{'status':'wrong'}, {'exit_status':True}, {'receipt_sha256':'0' * 64}, {'consumer_names':list(reversed(NAMES))}]:
            result_path.write_text(json.dumps({**original, **change}))
            with self.subTest(change=change), self.assertRaises(ValueError):
                M.seal(self.directory)
        result_path.write_text(json.dumps(original))
        receipt = M.read(self.directory / 'receipt.json')
        receipt['consumers'].pop()
        (self.directory / 'receipt.json').write_text(json.dumps(receipt))
        changed = {**original, 'receipt_sha256':M.fingerprint(self.directory / 'receipt.json')}
        result_path.write_text(json.dumps(changed))
        with self.assertRaises(ValueError):
            M.seal(self.directory)

    def test_seal_requires_successful_stop_and_cleanup_identity(self) -> None:
        record = self.finished()
        self.after_state['ActiveState'] = 'active'
        with self.assertRaises(ValueError):
            M.seal(self.directory)
        self.state.update(ActiveState='active', SubState='exited')
        self.after_state['ActiveState'] = 'inactive'
        self.after_state['Result'] = 'exit-code'
        with self.assertRaises(ValueError):
            M.seal(self.directory)
        self.state.update(ActiveState='active', SubState='exited', Result='success')
        self.after_state['Result'] = 'success'
        path = self.directory / 'cleanup.json'
        for change in [{'exit_status':1}, {'exit_status':False}, {'run_id':'0' * 32}, {'owner_label':'org.kataglyphis.other'}]:
            path.write_text(json.dumps({'exit_status':0, 'owner_label':M.OWNER, 'run_id':record['run_id'], **change}))
            with self.subTest(change=change), self.assertRaises(ValueError):
                M.seal(self.directory)
            self.state.update(ActiveState='active', SubState='exited', Result='success')
        self.assertFalse((self.directory / 'proof-stopped.json').exists())

    def test_failed_query_or_remaining_owned_container_never_passes(self) -> None:
        self.finished()
        self.query_status = 7
        with self.assertRaises(ValueError):
            M.seal(self.directory)
        self.assertEqual(M.read(self.directory / 'independent-engine-query.json')['returncode'], 7)
        self.assertFalse((self.directory / 'proof-stopped.json').exists())

    def test_remaining_owned_container_never_passes(self) -> None:
        self.finished()
        self.query_output = '{"ID":"owned"}\n'
        with self.assertRaises(ValueError):
            M.seal(self.directory)
        self.assertFalse((self.directory / 'proof-stopped.json').exists())

    def test_cli_dispatch_and_failed_seal_status_are_preserved(self) -> None:
        for action in ['worker', 'seal']:
            with mock.patch.object(sys, 'argv', ['launcher', action, '--directory', str(self.directory)]), mock.patch.object(M, action, return_value=1 if action == 'seal' else None) as call:
                self.assertEqual(M.main(), 1 if action == 'seal' else 0)
                call.assert_called_once_with(self.directory)
        argv = ['launcher', 'launch', '--directory', str(self.directory), '--runtime-invocation', str(self.fixture.invocation_path),
                '--image', self.fixture.reference, '--unit', self.unit]
        with mock.patch.object(sys, 'argv', argv), mock.patch.object(M, 'launch') as call:
            self.assertEqual(M.main(), 0)
            call.assert_called_once_with(self.fixture.invocation_path, self.fixture.reference, self.directory, self.unit)
        with mock.patch.object(sys, 'argv', ['launcher', 'launch', '--directory', str(self.directory)]), mock.patch('sys.stderr', new_callable=io.StringIO), self.assertRaises(SystemExit) as error:
            M.main()
        self.assertEqual(error.exception.code, 2)


    def test_worker_and_seal_retain_their_own_source_binding_calls(self) -> None:
        self.live_worker()
        self.code.write_text('# changed worker\n')
        with self.assertRaises(ValueError):
            M.worker(self.directory)
        self.assertFalse(self.check_args)

    def test_seal_rechecks_worker_bytes_before_stopping(self) -> None:
        self.finished()
        self.code.write_text('# changed worker\n')
        with self.assertRaises(ValueError):
            M.seal(self.directory)
        self.assertFalse(any(row[:3] == ['systemctl', '--user', 'stop'] for row in self.calls))

    def test_launch_rejects_corrupted_materialization_before_unit_start(self) -> None:
        def incomplete(source: str, output: str, platform: str) -> None:
            plan = copy.deepcopy(self.fixture.contract)
            plan['consumers'].pop()
            M.save(Path(output), plan)
        with mock.patch.dict(M.API, {'materialize_plan':incomplete}), self.assertRaises(ValueError):
            self.launch()
        self.assertFalse(any(row[:1] == ['systemd-run'] for row in self.calls))

    def test_worker_rejects_invalid_schema_even_with_matching_hub_and_producer(self) -> None:
        self.live_worker()
        self.receipt['schema_version'] = 1
        with self.assertRaises(ValueError):
            M.worker(self.directory)
        self.assertFalse((self.directory / 'worker-result.json').exists())

    def test_seal_rejects_invalid_schema_even_with_matching_worker_hash(self) -> None:
        self.finished()
        receipt = M.read(self.directory / 'receipt.json')
        receipt['schema_version'] = 1
        (self.directory / 'receipt.json').write_text(json.dumps(receipt))
        result = M.read(self.directory / 'worker-result.json')
        result['receipt_sha256'] = M.fingerprint(self.directory / 'receipt.json')
        (self.directory / 'worker-result.json').write_text(json.dumps(result))
        with self.assertRaises(ValueError):
            M.seal(self.directory)

    def test_seal_rechecks_current_image_and_producer(self) -> None:
        self.finished()
        self.recheck.side_effect = ValueError('Synthetic image changed after consumers')
        with self.assertRaisesRegex(ValueError, 'Synthetic image changed'):
            M.seal(self.directory)
        self.assertFalse(any(row[:3] == ['systemctl', '--user', 'stop'] for row in self.calls))


    def test_plan_platform_is_checked_after_other_bindings_match(self) -> None:
        record = self.launch()
        record.update(platform='linux/arm64', unit='webgpu-local-final-arm64-999-1.service')
        with self.assertRaises(ValueError):
            M.binding(self.directory, record)

    def test_unsupported_architecture_refuses_before_observing_or_allocating(self) -> None:
        self.fixture.invocation['target_arch'] = 'mips'
        self.fixture.save()
        self.unit = 'webgpu-local-final-mips-999-1.service'
        self.state['Id'] = self.unit
        with self.assertRaises(ValueError):
            self.launch()
        self.observe.assert_not_called()
        self.assertFalse(self.directory.exists())

    def test_failed_unit_still_requires_a_stopped_zero_pid(self) -> None:
        self.finished()
        self.state.update(ActiveState='failed', SubState='failed', Result='exit-code', ExecMainStatus='1')
        self.after_state.update(ActiveState='failed', MainPID='74', Result='exit-code')
        with self.assertRaises(ValueError):
            M.seal(self.directory)
        self.assertFalse((self.directory / 'proof-stopped.json').exists())

    def test_other_supported_architectures_keep_the_entire_plan(self) -> None:
        for arch in ['arm64', 'riscv64']:
            self.directory = self.root / ('bounded-' + arch)
            self.unit = 'webgpu-local-final-' + arch + '-999-1.service'
            self.state['Id'] = self.unit
            self.fixture.invocation['target_arch'] = arch
            self.fixture.save()
            record = self.launch()
            self.assertEqual(M.read(self.directory / 'plan.json'), {**self.fixture.contract, 'platform':'linux/' + arch})
            self.assertEqual(record['platform'], 'linux/' + arch)
            self.observe.assert_called_with(M.ENGINE, self.fixture.reference, 'linux/' + arch, self.fixture.invocation_path)

    def test_real_worker_inventory_carries_shared_engine_and_full_consumer_plan(self) -> None:
        self.assertIn(M.HERE / 'runtime_terminal_evidence.py', ORIGINAL_WORKERS())
        self.assertIn(M.HERE / 'owned-nerdctl.py', ORIGINAL_WORKERS())
        self.assertIn(M.ROOT / 'shared/config/image-consumers.json', ORIGINAL_WORKERS())
        self.assertIsNotNone(M.__file__)
        assert M.__file__ is not None
        self.assertIn(Path(M.__file__).resolve(), ORIGINAL_WORKERS())


if __name__ == '__main__':
    unittest.main()
