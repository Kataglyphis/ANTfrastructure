"""Synthetic storage lifecycle controls; no actual pruning, runtime, image or hardware acceptance."""

from __future__ import annotations

import contextlib
import io
import json
import runpy
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runtime_storage_guard as G

ORIGINAL_WORKERS = G.workers
ORIGINAL_LOCAL_API = G.local_api
ORIGINAL_READ_BYTES = Path.read_bytes


class StorageGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix='runtime-storage-tests-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.home = self.root / 'home'
        (self.home / '.cache').mkdir(parents=True)
        self.directory = self.root / 'watch'
        self.authorization = self.root / 'authorization.md'
        self.authorization.write_text('agents may run the existing ' + chr(96) + 'linux/host-config/prune-safe.sh' + chr(96) + ' autonomously')
        self.code = self.root / 'worker.py'
        self.code.write_text('# fixture worker\n')
        self.runtime_path = self.root / 'runtime.json'
        self.guard_unit = 'webgpu-safe-prune-runtime-amd64-999-1.service'
        self.producer_unit = 'webgpu-normal-runtime-amd64-999-1.service'
        self.driver = ['/bin/bash', '/source/linux/scripts/build-runtime-manifest.sh', '--image', 'ant-local/webgpu-fixture:runtime-1',
                       '--target-arches', 'amd64', '--artifact-image-prefix', 'ant-local/webgpu-fixture:android',
                       '--artifact-build-mode', 'cross', '--skip-manifest']
        self.runtime = {'stage':'runtime', 'launch_status':0, 'target_arch':'amd64', 'unit':self.producer_unit,
                        'command':['systemd-run', '--user', *self.driver]}
        self.runtime_path.write_text(json.dumps(self.runtime))
        self.live = {'Id':self.producer_unit, 'LoadState':'loaded', 'ActiveState':'activating', 'SubState':'start',
                     'MainPID':'73', 'Result':'success', 'ExecMainStatus':'0', 'ExecMainExitTimestampMonotonic':'0'}
        self.ended = {**self.live, 'ActiveState':'active', 'SubState':'exited', 'MainPID':'0', 'ExecMainExitTimestampMonotonic':'7'}
        self.guard_state = {'Id':self.guard_unit, 'LoadState':'not-found', 'ActiveState':'inactive', 'MainPID':'0'}
        self.clock, self.stop_at = 0, 3
        self.free = 20000000000
        self.records = [{'id':'regular-1', 'recordType':'regular', 'size':150000000000, 'inUse':True, 'shared':False}]
        self.calls: list[list[str]] = []
        self.options: list[dict[str, Any]] = []
        self.sleeps: list[int] = []
        self.head, self.dirty, self.ticks = 'a' * 40, '', '42'
        self.raw_status = 0
        self.proof_status = 'passed-authorized-canonical-layer-cleanup'
        self.on_sleep: Any = None
        self.skip_count = 0
        self.skip_changes: dict[str, Any] = {}
        patches = [mock.patch.dict(G.os.environ, {}), mock.patch.object(G, 'workers', return_value=[self.code]),
                   mock.patch.object(G, 'checked_output', side_effect=self.checked),
                   mock.patch.object(G, 'UNIT_API', side_effect=self.unit_state),
                   mock.patch.object(G, 'local_api', return_value=types.SimpleNamespace(start_ticks=lambda path:self.ticks)),
                   mock.patch.object(G.subprocess, 'run', side_effect=self.run_command),
                   mock.patch.object(Path, 'home', return_value=self.home),
                   mock.patch.object(Path, 'read_bytes', new=lambda path:self.read_bytes(path)),
                   mock.patch.object(G.shutil, 'disk_usage', side_effect=lambda path:types.SimpleNamespace(free=self.free)),
                   mock.patch.object(G.time, 'monotonic', side_effect=lambda:self.clock),
                   mock.patch.object(G.time, 'sleep', side_effect=self.sleep)]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def read_bytes(self, path: Path) -> bytes:
        if path == Path('/proc/73/cmdline'):
            return b'\0'.join(value.encode() for value in self.driver) + b'\0'
        return ORIGINAL_READ_BYTES(path)

    def checked(self, command: list[str]) -> str:
        self.calls.append(command)
        if command[:3] == ['git', '-C', str(G.ROOT)]:
            return self.head if command[-2:] == ['rev-parse', 'HEAD'] else self.dirty
        if command[:2] == ['buildctl', 'du']:
            return json.dumps(self.records)
        if command == ['systemctl', '--user', 'stop', self.guard_unit]:
            self.guard_state = {'Id':self.guard_unit, 'LoadState':'not-found', 'ActiveState':'inactive', 'MainPID':'0'}
            return ''
        raise AssertionError('Unexpected real command: ' + repr(command))

    def unit_state(self, unit: str) -> dict[str, str]:
        if unit == self.guard_unit:
            return dict(self.guard_state)
        if unit == self.producer_unit:
            return dict(self.ended if self.clock >= self.stop_at else self.live)
        raise AssertionError('Unexpected unit: ' + unit)

    def run_command(self, command: list[str], **options: Any) -> subprocess.CompletedProcess[str]:
        self.calls.append(command)
        self.options.append(options)
        if command[0] == 'systemd-run':
            return subprocess.CompletedProcess(command, self.raw_status, 'launched', 'diagnostic')
        if command[1:3] == [str(G.CONTROLLER), 'worker']:
            destination = Path(command[command.index('--directory') + 1])
            if self.skip_count:
                self.skip_count -= 1
                G.save(destination / 'skip-proof.json', {'status':'skipped-reserve-already-sufficient', 'reclaim_performed':False,
                       'free_bytes':200000000000, 'canonical_free_gib':186, **self.skip_changes})
            else:
                G.save(destination / 'proof.json', {'status':self.proof_status, 'keep_layer_gb':100,
                       'free_bytes_before':20000000000, 'free_bytes_after':70000000000})
            return subprocess.CompletedProcess(command, self.raw_status, '', '')
        raise AssertionError('Unexpected subprocess: ' + repr(command))

    def sleep(self, seconds: int) -> None:
        self.assertEqual(seconds, 1)
        self.sleeps.append(seconds)
        self.clock += seconds
        if self.on_sleep is not None:
            self.on_sleep()

    def launch(self) -> dict[str, Any]:
        G.launch(self.runtime_path, self.directory, self.guard_unit, self.authorization)
        return G.read(self.directory / 'invocation.json')

    def test_launch_installs_fixed_bounds_source_and_original_pid(self) -> None:
        record = self.launch()
        command = record['command']
        for value in ['--no-block', '--expand-environment=no', 'TimeoutStartSec=21630', 'TimeoutStopSec=60',
                      'KillMode=control-group', 'MemoryMax=256M', 'CPUQuota=25%', 'LC_ALL=C', 'HOME=' + str(self.home),
                      'TMPDIR=' + str(self.home / '.cache' / self.guard_unit.removesuffix('.service'))]:
            self.assertIn(value, command)
        self.assertEqual(record['producer_unit'], self.producer_unit)
        self.assertEqual(record['producer_pid'], 73)
        self.assertEqual(record['producer_start_ticks'], '42')
        self.assertEqual(record['keep_gb'], 100)
        self.assertEqual(record['timeout_seconds'], 21600)
        self.assertEqual(G.REQUIRED_BYTES, 193273528320)
        self.assertEqual(record['runtime_invocation_sha256'], G.fingerprint(self.runtime_path))
        self.assertEqual(command[-3:], ['worker', '--directory', str(self.directory)])
        self.assertEqual(G.read(self.directory / 'launch-result.json')['exit_status'], 0)

    def test_candidate_excludes_active_shared_cachemounts_and_sub_budget_layers(self) -> None:
        row = {'id':'unused', 'size':150000000000, 'recordType':'regular', 'inUse':False, 'shared':False}
        key, amount = G.candidate([row])
        self.assertTrue(key)
        self.assertEqual(amount, 50000000000)
        for change in [{'inUse':True}, {'shared':True}, {'recordType':'exec.cachemount'}, {'size':99000000000}]:
            with self.subTest(change=change):
                self.assertEqual(G.candidate([{**row, **change}]), ('', 0))
        self.assertEqual(G.candidate([row, {**row, 'id':'another', 'inUse':True}])[1], 150000000000)
        self.assertNotEqual(G.candidate([row])[0], G.candidate([{**row, 'id':'changed'}])[0])

    def test_candidate_rejects_malformed_record_sizes_and_ownership(self) -> None:
        for key, value in [('size', -1), ('size', True), ('size', '100'), ('id', ''), ('id', None), ('inUse', 'false'), ('shared', 0)]:
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                G.candidate([{**self.records[0], key:value}])

    def test_worker_waits_for_release_and_never_retries_an_unchanged_candidate(self) -> None:
        self.launch()
        self.on_sleep = lambda:self.records[0].update(inUse=False)
        self.assertEqual(G.worker(self.directory), 0)
        calls = [call for call in self.calls if call[1:3] == [str(G.CONTROLLER), 'worker']]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][calls[0].index('--keep-gb') + 1], '100')
        self.assertNotIn('--idle-store', calls[0])
        self.assertEqual(calls[0][calls[0].index('--unit') + 1], self.guard_unit)
        child = G.read(self.directory / 'prune-1/invocation.json')
        self.assertFalse(child['idle_store_required'])
        self.assertEqual(child['producer_state_at_dispatch'], self.live)
        self.assertEqual(child['canonical_script_sha256'], G.fingerprint(G.CANONICAL))
        result = G.read(self.directory / 'worker-result.json')
        self.assertEqual(len(result['prunes']), 1)
        self.assertFalse(result['build_or_image_accepted'])
        self.assertTrue(all(seconds == 1 for seconds in self.sleeps))
        self.assertEqual(self.options[-1]['timeout'], 540)

    def test_sufficient_space_skips_all_buildkit_and_cleanup_queries(self) -> None:
        self.launch()
        self.free = 200000000000
        self.records[0]['inUse'] = False
        self.assertEqual(G.worker(self.directory), 0)
        self.assertFalse(any(call[:2] == ['buildctl', 'du'] for call in self.calls))
        self.assertFalse((self.directory / 'prune-1').exists())

    def test_a_producer_ending_after_candidate_query_prevents_reclaim(self) -> None:
        self.launch()
        self.records[0]['inUse'] = False
        original = self.checked
        def ending(command: list[str]) -> str:
            value = original(command)
            if command[:2] == ['buildctl', 'du']:
                self.clock = self.stop_at
            return value
        with mock.patch.object(G, 'checked_output', side_effect=ending):
            self.assertEqual(G.worker(self.directory), 0)
        self.assertFalse((self.directory / 'prune-1').exists())

    def test_failed_producer_result_remains_failed_and_unaccepted(self) -> None:
        self.launch()
        self.clock = self.stop_at
        self.ended.update(ActiveState='failed', SubState='failed', Result='exit-code', ExecMainStatus='1')
        self.assertEqual(G.worker(self.directory), 1)
        self.assertFalse(G.read(self.directory / 'worker-result.json')['build_or_image_accepted'])

    def test_changed_pid_start_ticks_missing_unit_and_changed_source_refuse(self) -> None:
        record = self.launch()
        for key, value in [('Id', 'foreign.service'), ('LoadState', 'not-found'), ('MainPID', '74'), ('ActiveState', 'inactive')]:
            original = dict(self.live)
            self.live[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                G.producer_state(record)
            self.live = original
        self.ticks = '43'
        with self.assertRaises(ValueError):
            G.producer_state(record)
        self.ticks = '42'
        for key, value in [('source', '/other'), ('revision', 'b' * 40), ('keep_gb', 1), ('timeout_seconds', 1)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                G.source_binding({**record, key:value})
        self.dirty = ' M changed.py'
        with self.assertRaises(ValueError):
            G.source_binding(record)

    def test_changed_companion_authorization_or_runtime_bytes_refuse(self) -> None:
        record = self.launch()
        for path in [self.code, self.authorization, self.runtime_path]:
            original = path.read_text()
            path.write_text(original + 'changed')
            with self.subTest(path=path), self.assertRaises(ValueError):
                G.source_binding(record)
            path.write_text(original)

    def test_existing_output_unit_bad_runtime_or_missing_authorization_refuse(self) -> None:
        self.guard_state['LoadState'] = 'loaded'
        with self.assertRaises(ValueError):
            self.launch()
        self.guard_state['LoadState'] = 'not-found'
        self.directory.mkdir()
        with self.assertRaises(ValueError):
            self.launch()
        self.directory.rmdir()
        for key, value in [('stage', 'media'), ('launch_status', True), ('launch_status', 1),
                           ('target_arch', 'mips'), ('unit', 'foreign.service')]:
            self.runtime_path.write_text(json.dumps({**self.runtime, key:value}))
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.launch()
        self.runtime_path.write_text(json.dumps(self.runtime))
        self.authorization.write_text('not authorized')
        with self.assertRaises(ValueError):
            self.launch()

    def test_runtime_end_wrong_cmdline_and_git_ancestor_refuse_before_launch(self) -> None:
        self.clock = self.stop_at
        with self.assertRaises(ValueError):
            self.launch()
        self.clock = 0
        self.driver[1] = '/other/script.sh'
        with self.assertRaises(ValueError):
            self.launch()
        self.driver[1] = '/source/linux/scripts/build-runtime-manifest.sh'
        (self.home / '.git').mkdir()
        with self.assertRaises(ValueError):
            self.launch()
        self.assertFalse(any(call[0] == 'systemd-run' for call in self.calls))

    def test_canonical_child_failure_wrong_proof_and_existing_evidence_refuse(self) -> None:
        record = self.launch()
        self.raw_status = 47
        with self.assertRaises(ValueError):
            G.reclaim(self.directory, record, 1, self.live)
        self.raw_status = 0
        self.proof_status = 'foreign'
        with self.assertRaises(ValueError):
            G.reclaim(self.directory, record, 2, self.live)
        with self.assertRaises(ValueError):
            G.reclaim(self.directory, record, 1, self.live)

    def test_guardian_timeout_does_not_change_the_producer(self) -> None:
        self.launch()
        self.free = 200000000000
        self.on_sleep = lambda:setattr(self, 'clock', 21601)
        with self.assertRaises(TimeoutError):
            G.worker(self.directory)
        self.assertFalse(any(call[:3] == ['systemctl', '--user', 'stop'] for call in self.calls))
        self.assertFalse((self.directory / 'worker-result.json').exists())

    def test_unit_launch_failure_retains_its_raw_status_and_diagnostics(self) -> None:
        self.raw_status = 19
        with self.assertRaises(ValueError):
            self.launch()
        result = G.read(self.directory / 'launch-result.json')
        self.assertEqual(result['exit_status'], 19)
        self.assertEqual(result['stderr'], 'diagnostic')

    def test_seal_requires_real_terminal_and_preserves_the_exact_cleanup_proof(self) -> None:
        record = self.launch()
        self.clock = self.stop_at
        G.worker(self.directory)
        self.guard_state = {**self.ended, 'Id':self.guard_unit}
        G.seal(self.directory)
        proof = G.read(self.directory / 'proof-stopped.json')
        self.assertFalse(proof['build_or_image_accepted'])
        self.assertEqual(proof['stopped']['ActiveState'], 'inactive')
        self.assertEqual(proof['producer_result']['Id'], record['producer_unit'])
        self.guard_state = {**self.ended, 'Id':self.guard_unit}
        with self.assertRaises(ValueError):
            G.seal(self.directory)

    def test_skipped_cleanup_is_retried_when_the_same_pressure_returns(self) -> None:
        self.launch()
        self.records[0]['inUse'] = False
        self.skip_count = 1
        self.assertEqual(G.worker(self.directory), 0)
        result = G.read(self.directory / 'worker-result.json')
        self.assertEqual([row['skipped'] for row in result['prunes']], [True, False])
        self.assertEqual(len([call for call in self.calls if call[1:3] == [str(G.CONTROLLER), 'worker']]), 2)

    def test_false_skip_proofs_are_refused(self) -> None:
        record = self.launch()
        self.skip_count = 1
        for index, change in enumerate([{'status':'foreign'}, {'reclaim_performed':True},
                                        {'free_bytes':1}, {'canonical_free_gib':179}], 1):
            self.skip_count = 1
            self.skip_changes = change
            with self.subTest(change=change), self.assertRaises(ValueError):
                G.reclaim(self.directory, record, index, self.live)

    def test_launcher_checks_source_before_allocating_the_watcher(self) -> None:
        self.dirty = ' M changed.py'
        with self.assertRaises(ValueError):
            self.launch()
        self.assertFalse(self.directory.exists())
        self.assertFalse(any(call[0] == 'systemd-run' for call in self.calls))

    def test_worker_requires_source_binding_before_polling_and_before_cleanup(self) -> None:
        self.launch()
        with mock.patch.object(G, 'source_binding', side_effect=ValueError('required source')), self.assertRaisesRegex(ValueError, 'required source'):
            G.worker(self.directory)
        self.assertFalse((self.directory / 'observations.jsonl').exists())
        self.records[0]['inUse'] = False
        with mock.patch.object(G, 'source_binding', side_effect=[None, ValueError('required second source')]), self.assertRaisesRegex(ValueError, 'required second source'):
            G.worker(self.directory)
        self.assertFalse((self.directory / 'prune-1').exists())

    def test_changed_eligible_pressure_gets_a_new_fingerprint(self) -> None:
        row = {**self.records[0], 'inUse':False}
        active = {**row, 'id':'active', 'inUse':True, 'size':100000000000}
        self.assertNotEqual(G.candidate([row])[0], G.candidate([row, active])[0])
        record = self.launch()
        for key, value in [('unit', self.producer_unit), ('keep_gb', 100.0), ('timeout_seconds', 21600.0)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                G.source_binding({**record, key:value})

    def prepare_seal(self) -> dict[str, Any]:
        record = self.launch()
        self.records[0]['inUse'] = False
        G.worker(self.directory)
        self.guard_state = {**self.ended, 'Id':self.guard_unit}
        return record

    def test_seal_rejects_missing_wrong_or_nonterminal_controller_state(self) -> None:
        self.prepare_seal()
        original = dict(self.guard_state)
        changes = [{'Id':'foreign.service'}, {'LoadState':'not-found'}, {'MainPID':'73'},
                   {'ExecMainStatus':'1'}, {'Result':'timeout', 'ActiveState':'failed', 'SubState':'failed'}, {'ActiveState':'activating', 'SubState':'start', 'MainPID':'73', 'ExecMainExitTimestampMonotonic':'0'}]
        for change in changes:
            self.guard_state = {**original, **change}
            with self.subTest(change=change), self.assertRaises(ValueError):
                G.seal(self.directory)
        self.assertFalse((self.directory / 'proof-stopped.json').exists())

    def test_seal_rejects_changed_result_cleanup_bytes_or_external_proof_path(self) -> None:
        self.prepare_seal()
        path = self.directory / 'worker-result.json'
        original = G.read(path)
        changed = {**original, 'status':'foreign'}
        path.write_text(json.dumps(changed))
        with self.assertRaises(ValueError):
            G.seal(self.directory)
        path.write_text(json.dumps(original))
        proof = Path(original['prunes'][0]['proof_file'])
        content = proof.read_text()
        proof.write_text(content + '\n')
        with self.assertRaises(ValueError):
            G.seal(self.directory)
        proof.write_text(content)
        outside = self.root / 'foreign-proof.json'
        outside.write_text(content)
        changed = G.read(path)
        changed['prunes'][0]['proof_file'] = str(outside)
        path.write_text(json.dumps(changed))
        with self.assertRaises(ValueError):
            G.seal(self.directory)
        self.assertFalse((self.directory / 'proof-stopped.json').exists())

    def test_seal_rejects_a_green_guardian_receipt_with_a_failed_producer(self) -> None:
        self.prepare_seal()
        path = self.directory / 'worker-result.json'
        result = G.read(path)
        result['producer'] = {**self.ended, 'ActiveState':'failed', 'SubState':'failed', 'Result':'exit-code', 'ExecMainStatus':'1'}
        path.write_text(json.dumps(result))
        with self.assertRaisesRegex(ValueError, 'outcomes differ'):
            G.seal(self.directory)
        self.assertFalse((self.directory / 'proof-stopped.json').exists())

    def test_failed_stop_cannot_produce_a_stopped_receipt(self) -> None:
        self.prepare_seal()
        original = self.checked
        def keep_running(command: list[str]) -> str:
            return '' if command == ['systemctl', '--user', 'stop', self.guard_unit] else original(command)
        with mock.patch.object(G, 'checked_output', side_effect=keep_running), self.assertRaisesRegex(ValueError, 'did not stop'):
            G.seal(self.directory)
        self.assertFalse((self.directory / 'proof-stopped.json').exists())

    def test_cli_dispatches_launch_seal_and_rejects_foreign_warm_module(self) -> None:
        entry = G.HERE / 'launch-runtime-storage-guard.py'
        arguments = [str(entry), 'launch', '--directory', str(self.directory), '--runtime-invocation', str(self.runtime_path),
                     '--unit', self.guard_unit, '--authorization', str(self.authorization)]
        with mock.patch.object(sys, 'argv', arguments), self.assertRaises(SystemExit) as error:
            runpy.run_path(str(entry), run_name='__main__')
        self.assertEqual(error.exception.code, 0)
        self.clock = self.stop_at
        G.worker(self.directory)
        self.guard_state = {**self.ended, 'Id':self.guard_unit}
        with mock.patch.object(sys, 'argv', [str(entry), 'seal', '--directory', str(self.directory)]), self.assertRaises(SystemExit) as error:
            runpy.run_path(str(entry), run_name='__main__')
        self.assertEqual(error.exception.code, 0)
        self.assertTrue((self.directory / 'proof-stopped.json').is_file())
        with mock.patch.object(G, '__file__', '/foreign/runtime_storage_guard.py'), mock.patch.object(G, 'launch', side_effect=AssertionError('foreign companion must not dispatch')), mock.patch.object(sys, 'argv', arguments), self.assertRaises(ValueError):
            runpy.run_path(str(entry), run_name='__main__')

    def test_invalid_guardian_unit_is_refused_before_any_unit_query(self) -> None:
        with mock.patch.object(G, 'UNIT_API', side_effect=AssertionError('must not query')), self.assertRaises(ValueError):
            G.launch(self.runtime_path, self.directory, 'foreign.service', self.authorization)

    def test_launch_refuses_nonlive_metadata_even_with_a_matching_pid(self) -> None:
        original = dict(self.live)
        for key, value in [('Id', 'foreign.service'), ('LoadState', 'not-found'), ('ActiveState', 'inactive'), ('MainPID', '0')]:
            self.live = {**original, key:value}
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.launch()
        self.assertFalse(self.directory.exists())

    def test_unsupported_architecture_cannot_hide_behind_an_otherwise_bound_process(self) -> None:
        self.producer_unit = 'webgpu-normal-runtime-mips-999-1.service'
        self.live['Id'] = self.producer_unit
        self.driver[5] = 'mips'
        self.runtime.update(target_arch='mips', unit=self.producer_unit, command=['systemd-run', '--user', *self.driver])
        self.runtime_path.write_text(json.dumps(self.runtime))
        with self.assertRaises(ValueError):
            self.launch()
        self.assertFalse(self.directory.exists())

    def test_worker_uses_the_original_rootless_store_and_restores_no_host_state(self) -> None:
        self.launch()
        G.os.environ['BUILDKIT_HOST'] = 'unix:///foreign.sock'
        self.clock = self.stop_at
        G.worker(self.directory)
        self.assertEqual(G.os.environ['BUILDKIT_HOST'], 'unix:///run/user/' + str(G.os.getuid()) + '/buildkit/buildkitd.sock')

    def test_cached_failed_unit_without_an_exit_timestamp_cannot_be_sealed(self) -> None:
        self.launch()
        self.clock = self.stop_at
        self.ended.update(ActiveState='failed', SubState='failed', Result='exit-code', ExecMainStatus='1')
        G.worker(self.directory)
        self.guard_state = {**self.ended, 'Id':self.guard_unit, 'ExecMainExitTimestampMonotonic':'0'}
        with self.assertRaises(ValueError):
            G.seal(self.directory)
        self.assertFalse((self.directory / 'proof-stopped.json').exists())

    def test_actual_capture_companion_loads_cold_and_exports_the_start_identity_api(self) -> None:
        module = ORIGINAL_LOCAL_API('capture-live-sccache-log')
        process = self.root / 'process'
        process.mkdir()
        (process / 'stat').write_text('73 (fixture process) ' + ' '.join(['S', *(['0'] * 18), '1234']) + '\n')
        self.assertEqual(module.start_ticks(process), '1234')

    def test_worker_closure_contains_each_required_companion(self) -> None:
        expected = {'linux/scripts/runtime_storage_guard.py', 'linux/scripts/launch-runtime-storage-guard.py',
                    'linux/scripts/host_commands.py', 'linux/scripts/image_acceptance_local.py',
                    'linux/scripts/source_ci/common.py', 'linux/scripts/seal-mutation-unit.py',
                    'linux/scripts/watch-build-units.py', 'linux/scripts/local-proof/capture-live-sccache-log.py',
                    'linux/scripts/local-proof/cache_capture_profile.py', 'linux/host-config/autonomous-safe-prune.py',
                    'linux/host-config/prune-safe.sh', 'linux/host-config/verify-safe-prune.py',
                    'linux/host-config/nerdctl-full-state.py', 'linux/scripts/01-core/disk-guard.sh'}
        self.assertEqual({str(path.relative_to(G.ROOT)) for path in ORIGINAL_WORKERS()}, expected)

    def test_cli_requires_launch_inputs_and_propagates_worker_status(self) -> None:
        entry = G.HERE / 'launch-runtime-storage-guard.py'
        with mock.patch.object(sys, 'argv', [str(entry), 'launch', '--directory', str(self.directory)]), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            runpy.run_path(str(entry), run_name='__main__')
        self.assertEqual(error.exception.code, 2)
        with mock.patch.object(sys, 'argv', [str(entry), 'worker', '--directory', str(self.directory)]), mock.patch.object(G, 'worker', return_value=17), self.assertRaises(SystemExit) as error:
            runpy.run_path(str(entry), run_name='__main__')
        self.assertEqual(error.exception.code, 17)


if __name__ == '__main__':
    unittest.main()
