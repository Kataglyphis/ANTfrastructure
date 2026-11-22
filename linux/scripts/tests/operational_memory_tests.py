"""Independent append/controller fixtures exercise failures, not a real user bus or adversarial writer exclusion."""

from __future__ import annotations

import contextlib
import fcntl
import hashlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

MEMORY = sys.modules['operational_memory']
GUARD = sys.modules['operational_memory_guard']
ENTRY = globals()['g']


class MemoryTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix='operational-memory-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.memory = self.root / 'memory with spaces.md'
        self.append = self.root / 'append.md'
        self.directory = self.root / 'proof'
        self.before = 'Grüße\r\nOriginal\n'.encode()
        self.addition = '\nMehr Notizen: 🐜\n'.encode()
        self.memory.write_bytes(self.before)
        self.append.write_bytes(self.addition)
        self.proc = self.root / 'proc'
        self.proc.mkdir()
        self.states: list[dict[str, str]] = []
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(mock.patch.object(GUARD, 'PROC', self.proc))
        self.query = self.stack.enter_context(mock.patch.object(GUARD, 'checked_output', side_effect=self.command))

    def command(self, argv: list[str]) -> str:
        if argv[2] == 'list-units':
            return json.dumps([{'unit': state['Id'], 'load': state['LoadState'],
                                'active': state['ActiveState'], 'sub': state['SubState']} for state in self.states])
        self.assertEqual(argv[:3], ['systemctl', '--user', 'show'])
        state = next(state for state in self.states if state['Id'] == argv[3])
        return '\n'.join(key + '=' + value for key, value in state.items())

    def controller(self, **changes: str) -> None:
        self.states = [{'Id': 'webgpu-safe-prune-old.service', 'LoadState': 'loaded', 'ActiveState': 'failed',
                        'SubState': 'failed', 'MainPID': '0', 'ControlPID': '0'}]
        self.states[0].update(changes)

    def process(self, name: str, arguments: bytes) -> Path:
        process = self.proc / name
        process.mkdir()
        (process / 'cmdline').write_bytes(arguments)
        return process / 'cmdline'

    def run_append(self, **changes: Any) -> dict[str, Any]:
        args = {'memory': self.memory, 'expected_bytes': len(self.before),
                'expected_sha256': hashlib.sha256(self.before).hexdigest(),
                'append_file': self.append, 'directory': self.directory}
        args.update(changes)
        return MEMORY.append_memory(**args)

    def refused(self, **changes: Any) -> None:
        with self.assertRaises((OSError, ValueError, RuntimeError)):
            self.run_append(**changes)
        self.assertEqual(self.memory.read_bytes(), self.before)
        self.assertFalse((changes.get('directory', self.directory) / 'proof.json').exists())

    def test_exact_unicode_and_CRLF_prefix_and_append_snapshots(self) -> None:
        proof = self.run_append()
        self.assertEqual(self.memory.read_bytes(), self.before + self.addition)
        self.assertEqual((self.directory / 'prefix-before.bin').read_bytes(), self.before)
        self.assertEqual((self.directory / 'append.bin').read_bytes(), self.addition)
        self.assertEqual(proof['after_sha256'], hashlib.sha256(self.before + self.addition).hexdigest())
        self.assertEqual(json.loads((self.directory / 'proof.json').read_text()), proof)
        self.assertFalse(proof['runtime_GPU_image_quality_or_goal_acceptance'])

    def test_failed_or_exited_PID_zero_controllers_are_terminal(self) -> None:
        for active, sub in [('failed', 'failed'), ('inactive', 'dead'), ('active', 'exited')]:
            self.controller(ActiveState=active, SubState=sub)
            self.assertEqual(GUARD.controller_absence()['matching_controller_processes'], [])

    def test_live_main_or_control_PID_and_unknown_states_refuse(self) -> None:
        for changes in [{'MainPID': '4'}, {'ControlPID': '5'}, {'MainPID': '-1'},
                        {'ActiveState': 'active', 'SubState': 'running'}, {'SubState': 'unknown'}]:
            self.controller(**changes)
            self.refused()

    def test_failed_or_malformed_unit_transport_refuses(self) -> None:
        for value in [RuntimeError('bus failed'), 'bad json', '{}', '[null]', '[{"unit":"foreign.service"}]']:
            self.query.side_effect = value if isinstance(value, Exception) else None
            self.query.return_value = value
            self.refused()

    def test_incomplete_duplicate_foreign_and_changed_unit_properties_refuse(self) -> None:
        self.controller()
        original = self.command(['systemctl', '--user', 'show', self.states[0]['Id']])
        for state in [original.replace('MainPID=0', ''), original + '\nMainPID=0',
                      original.replace('Id=webgpu-safe-prune-old.service', 'Id=foreign.service'),
                      original.replace('ActiveState=failed', 'ActiveState=inactive')]:
            self.query.side_effect = [('[{"unit":"webgpu-safe-prune-old.service","load":"loaded",'
                                       '"active":"failed","sub":"failed"}]'), state]
            self.refused()

    def test_duplicate_unit_entries_refuse(self) -> None:
        self.controller()
        self.states.append(dict(self.states[0]))
        self.refused()

    def test_live_named_processes_include_ancestors_and_underscore_spellings(self) -> None:
        for argument in [b'python3\0runtime_storage_guard.py\0', b'bash\0safe-prune.sh\0',
                         b'bash\0-c\0\npython3 storage-guardian.py\n\0']:
            cmdline = self.process('999999', argument)
            self.refused()
            cmdline.unlink()
            cmdline.parent.rmdir()

    def test_only_the_current_process_is_excluded(self) -> None:
        self.process(str(os.getpid()), b'own-storage-guardian-argument\0')
        self.assertEqual(GUARD.controller_absence()['matching_controller_processes'], [])
        self.process(str(os.getppid()), b'python3\0storage-guardian.py\0')
        self.refused()

    def test_unreadable_proc_is_fatal_but_disappeared_process_is_not_live(self) -> None:
        target = self.process('999998', b'ordinary\0')
        original = Path.read_bytes
        for error in [PermissionError('unreadable'), FileNotFoundError('gone')]:
            def reading(path: Path, error: OSError = error) -> bytes:
                if path == target:
                    raise error
                return original(path)
            with mock.patch.object(Path, 'read_bytes', reading):
                if isinstance(error, PermissionError):
                    self.refused()
                else:
                    self.assertEqual(GUARD.controller_absence()['matching_controller_processes'], [])

    def test_missing_proc_root_is_unknown_and_refuses(self) -> None:
        self.proc.rmdir()
        self.refused()

    def test_wrong_expected_size_or_hash_refuses_before_any_append(self) -> None:
        for changes in [{'expected_bytes': 0}, {'expected_sha256': '0' * 64},
                        {'expected_bytes': -1}, {'expected_bytes': True}, {'expected_sha256': 'bad'}]:
            self.refused(**changes)

    def test_empty_invalid_UTF8_or_self_append_refuses(self) -> None:
        for value in [b'', b'\xff']:
            self.append.write_bytes(value)
            self.refused()
        self.refused(append_file=self.memory)

    def test_symlink_hardlink_and_FIFO_append_inputs_refuse(self) -> None:
        for name, setup in [('symlink', lambda path: path.symlink_to(self.append)),
                            ('hardlink', lambda path: os.link(self.append, path)),
                            ('fifo', os.mkfifo)]:
            path = self.root / name
            setup(path)
            self.refused(append_file=path)
            path.unlink()

    def test_symlink_and_hardlink_memory_refuse(self) -> None:
        link = self.root / 'memory-link'
        link.symlink_to(self.memory)
        self.refused(memory=link)
        link.unlink()
        os.link(self.memory, link)
        self.refused()

    def test_existing_proof_directory_and_backup_refuse_without_overwrite(self) -> None:
        self.directory.mkdir()
        sentinel = self.directory / 'prefix-before.bin'
        sentinel.write_bytes(b'retain')
        self.refused()
        self.assertEqual(sentinel.read_bytes(), b'retain')

    def test_backup_or_fsync_failure_cannot_modify_memory(self) -> None:
        for name in ['persist', 'sync_directory']:
            destination = self.root / name
            with mock.patch.object(MEMORY, name, side_effect=OSError('disk failed')):
                self.refused(directory=destination)

    def test_backup_bytes_must_match_before_memory_changes(self) -> None:
        original = MEMORY.persist
        def changed(path: Path, data: bytes) -> None:
            original(path, data[:1])
        with mock.patch.object(MEMORY, 'persist', side_effect=changed):
            self.refused()

    def test_changed_prefix_after_observation_is_not_appended(self) -> None:
        original = MEMORY.sync_directory
        def changed(path: Path) -> None:
            original(path)
            if path == self.directory.parent:
                self.memory.write_bytes(b'other writer')
        with mock.patch.object(MEMORY, 'sync_directory', side_effect=changed), self.assertRaises(ValueError):
            self.run_append()
        self.assertEqual(self.memory.read_bytes(), b'other writer')
        self.assertFalse((self.directory / 'proof.json').exists())

    def test_replaced_memory_path_is_not_reported_as_appended(self) -> None:
        original = MEMORY.sync_directory
        def replaced(path: Path) -> None:
            original(path)
            if path == self.directory.parent:
                self.memory.unlink()
                self.memory.write_bytes(b'new file')
        with mock.patch.object(MEMORY, 'sync_directory', side_effect=replaced), self.assertRaises(ValueError):
            self.run_append()
        self.assertEqual(self.memory.read_bytes(), b'new file')

    def test_concurrent_suffix_is_never_overwritten_and_no_pass_is_written(self) -> None:
        original = MEMORY.write_append
        def concurrent(descriptor: int, data: bytes) -> None:
            with self.memory.open('ab') as stream:
                stream.write(b'CONCURRENT')
            original(descriptor, data)
        with mock.patch.object(MEMORY, 'write_append', side_effect=concurrent), self.assertRaises(ValueError):
            self.run_append()
        self.assertEqual(self.memory.read_bytes(), self.before + b'CONCURRENT' + self.addition)
        self.assertFalse((self.directory / 'proof.json').exists())

    def test_changed_snapshot_after_append_cannot_produce_passed_proof(self) -> None:
        original = MEMORY.write_append
        for name in ['prefix-before.bin', 'append.bin']:
            self.memory.write_bytes(self.before)
            destination = self.root / (name + '.proof')
            def corrupted(descriptor: int, data: bytes, target: Path = destination / name) -> None:
                original(descriptor, data)
                target.write_bytes(b'changed snapshot')
            with self.subTest(snapshot=name):
                with mock.patch.object(MEMORY, 'write_append', side_effect=corrupted), self.assertRaisesRegex(ValueError, 'Backup bytes changed'):
                    self.run_append(directory=destination)
                self.assertEqual(self.memory.read_bytes(), self.before + self.addition)
                self.assertFalse((destination / 'proof.json').exists())

    def test_partial_append_writes_are_completed(self) -> None:
        original = os.write
        with mock.patch.object(MEMORY.os, 'write', side_effect=lambda fd, data: original(fd, data[:2])):
            self.run_append()
        self.assertEqual(self.memory.read_bytes(), self.before + self.addition)

    def test_zero_write_and_postwrite_fsync_failures_never_get_passed_proof(self) -> None:
        with mock.patch.object(MEMORY.os, 'write', side_effect=[0, OSError('zero-write retry')]), self.assertRaises(ValueError):
            self.run_append()
        self.assertEqual(self.memory.read_bytes(), self.before)
        self.assertFalse((self.directory / 'proof.json').exists())
        original = os.fsync
        def failed_sync(descriptor: int) -> None:
            if os.fstat(descriptor).st_ino == self.memory.stat().st_ino:
                raise OSError('memory fsync failed')
            original(descriptor)
        destination = self.root / 'postwrite-fsync'
        with mock.patch.object(MEMORY.os, 'fsync', side_effect=failed_sync), self.assertRaises(OSError):
            self.run_append(directory=destination)
        self.assertEqual(self.memory.read_bytes(), self.before + self.addition)
        self.assertFalse((destination / 'proof.json').exists())

    def test_failed_receipt_write_is_fatal_and_old_expected_prefix_cannot_replay(self) -> None:
        original = MEMORY.save
        def failed_proof(path: Path, value: Any) -> None:
            if path.name == 'proof.json':
                raise OSError('proof write failed')
            original(path, value)
        with mock.patch.object(MEMORY, 'save', side_effect=failed_proof), self.assertRaises(OSError):
            self.run_append()
        self.assertEqual(self.memory.read_bytes(), self.before + self.addition)
        self.assertFalse((self.directory / 'proof.json').exists())
        with self.assertRaisesRegex(ValueError, 'prefix differs'):
            self.run_append(directory=self.root / 'retry')
        self.assertEqual(self.memory.read_bytes(), self.before + self.addition)

    def test_a_cooperating_writer_lock_is_not_waited_out(self) -> None:
        with self.memory.open('rb') as stream:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.refused()

    def test_CLI_failure_has_nonzero_status_and_leaves_memory_unchanged(self) -> None:
        args = ['append-operational-memory.py', '--memory', str(self.memory), '--expected-bytes', str(len(self.before)),
                '--expected-sha256', '0' * 64, '--append-file', str(self.append), '--directory', str(self.directory)]
        with mock.patch.object(sys, 'argv', args), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as result:
            ENTRY.main()
        self.assertEqual(result.exception.code, 1)
        self.assertEqual(self.memory.read_bytes(), self.before)


if __name__ == '__main__':
    unittest.main()
