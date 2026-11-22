"""Synthetic recovery controls do not authenticate receipts or execute a real service, image or GPU."""

from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

from image_acceptance_local_fixture import LOCAL, MAIN, NAMES, LocalFixture
from runtime_terminal_fixture import EVIDENCE, TerminalFixture


class TerminalTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix='runtime-terminal-')
        self.addCleanup(temporary.cleanup)
        self.local = LocalFixture(Path(temporary.name))
        self.fixture = TerminalFixture(self.local)

    def origin(self) -> dict[str, Any]:
        with self.fixture.commands():
            return LOCAL.producer_inputs(self.local.invocation, self.local.invocation_path, self.local.platform)

    def test_retained_actual_exit_and_fresh_journal_cover_complete_six_consumer_contract(self) -> None:
        with self.fixture.commands():
            MAIN.check(self.local.args)
        receipt = json.loads(Path(self.local.args.receipt).read_text())
        self.assertEqual(receipt['status'], 'passed')
        self.assertEqual([row['name'] for row in receipt['consumers']], NAMES)
        origin = receipt['local_subject']
        self.assertEqual(origin['unit']['observation_source'], 'sealed-storage-guardian')
        self.assertEqual(origin['exit_timestamp_monotonic'], 7)
        self.assertEqual(origin['terminal_evidence']['journal']['events'][1]['__MONOTONIC_TIMESTAMP'], '8')
        self.assertEqual(origin, receipt['local_subject_after'])
        self.assertEqual(self.fixture.binding.call_count, 2)
        self.local.full_source.assert_called()
        self.assertEqual(sum(c[0] == 'journalctl' for c in self.local.calls), 2)

    def test_foreign_host_refuses_before_importing_guardian_code(self) -> None:
        self.local.invocation['host_tools_revision'] = self.fixture.record['revision'] = 'd' * 40
        self.local.save()
        self.fixture.record['runtime_invocation_sha256'] = LOCAL.fingerprint(self.local.invocation_path)
        self.fixture.save()
        with self.assertRaisesRegex(ValueError, 'host source revision'):
            self.origin()
        self.fixture.binding.assert_not_called()

    def test_nonmissing_terminal_failures_cannot_recover(self) -> None:
        self.local.terminal.side_effect = AssertionError('Producer failed')
        with self.assertRaisesRegex(ValueError, 'Producer failed'):
            self.origin()
        self.fixture.binding.assert_not_called()

    def test_missing_source_assertion_never_enters_terminal_recovery(self) -> None:
        self.local.full_source.side_effect = AssertionError('Producer unit is missing')
        with self.assertRaisesRegex(ValueError, 'source or terminal producer failed'):
            self.origin()
        self.fixture.binding.assert_not_called()
        self.assertFalse(any(c[0] == 'journalctl' for c in self.local.calls))

    def test_retained_producer_fields_must_each_prove_actual_success(self) -> None:
        original = copy.deepcopy(self.fixture.worker['producer'])
        for key, value in [('Id','foreign'), ('LoadState','not-found'), ('ActiveState','failed'),
                           ('SubState','dead'), ('MainPID','1'), ('ExecMainStatus','1'), ('Result','exit-code'),
                           ('ExecMainExitTimestampMonotonic','0')]:
            changed = {**original, key:value}
            self.fixture.worker['producer'] = self.fixture.seal['producer_result'] = changed
            self.fixture.save()
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.origin()
        self.fixture.worker['producer'] = self.fixture.seal['producer_result'] = original
        self.fixture.save()

    def test_consistently_invalid_manager_identity_or_clock_is_rejected(self) -> None:
        original = copy.deepcopy(self.local.journal_rows)
        for key, value in [('_PID','0'), ('_PID',99), ('JOB_ID','0'), ('JOB_ID',99), ('USER_INVOCATION_ID','invalid'),
                           ('USER_INVOCATION_ID',None), ('__MONOTONIC_TIMESTAMP','0'),
                           ('__MONOTONIC_TIMESTAMP',8), ('__REALTIME_TIMESTAMP','0'),
                           ('__REALTIME_TIMESTAMP',None), ('UNIT_RESULT','exit-code')]:
            for row in self.local.journal_rows:
                row[key] = value
            with self.subTest(key=key,value=value), self.assertRaises(ValueError):
                self.origin()
            self.local.journal_rows = copy.deepcopy(original)

    def test_receipt_rechecks_journal_and_observer_after_all_consumers(self) -> None:
        command = self.local.consumer_command
        for kind in ('journal','observer'):
            original_rows = copy.deepcopy(self.local.journal_rows)
            def changed(command_args: list, options: dict, kind: str = kind) -> tuple:
                result = command(command_args, options)
                if kind == 'journal':
                    self.local.journal_rows[1]['__MONOTONIC_TIMESTAMP'] = '9'
                else:
                    self.fixture.worker['note'] = 'changed during consumers'
                    self.fixture.save()
                return result
            with self.subTest(kind=kind), self.fixture.commands(), mock.patch.object(self.local, 'consumer_command', side_effect=changed), self.assertRaises(ValueError):
                MAIN.check(self.local.args)
            self.local.journal_rows = original_rows
            self.fixture.worker.pop('note', None)
            self.fixture.save()

    def test_terminal_object_list_and_live_evidence_shapes_refuse(self) -> None:
        path = self.fixture.directory / 'wrong-shape.json'
        path.write_text('[]')
        with self.assertRaises(ValueError):
            EVIDENCE._object(path)
        with self.assertRaises(ValueError):
            EVIDENCE.successful_unit([], self.local.unit)
        with self.assertRaises(ValueError):
            EVIDENCE.successful_unit({**self.fixture.worker['producer'], 'ExecMainExitTimestampMonotonic':'0'}, self.local.unit)
        with self.assertRaises(ValueError):
            EVIDENCE._prune_proofs((), self.fixture.directory)
        with self.assertRaises(ValueError):
            EVIDENCE._prune_proofs([''], self.fixture.directory)
        with self.assertRaises(ValueError):
            EVIDENCE.validate({'unit':{}, 'terminal_evidence':{}})

    def test_journal_payload_type_constraints_are_independent(self) -> None:
        original = self.origin()['terminal_evidence']['journal']
        changes: list[tuple[str, Any]] = [('events',tuple(original['events'])), ('driver',original['driver'] + ['foreign']),
                   ('boot_id','invalid'), ('uid',True)]
        for key, value in changes:
            changed = copy.deepcopy(original)
            changed[key] = value
            if key == 'driver':
                import shlex
                for index, row in enumerate(changed['events']):
                    row['MESSAGE'] = '[systemd-run] ' + shlex.join(value) + ('.' if index % 2 else '...')
            if key == 'boot_id':
                for row in changed['events']:
                    row['_BOOT_ID'] = value
            if key == 'uid':
                for row in changed['events']:
                    row['_UID'], row['_SYSTEMD_UNIT'] = str(value), f'user@{value}.service'
            with self.subTest(key=key), self.assertRaises(ValueError):
                EVIDENCE.journal_proof(changed, self.local.unit, 7)

    def test_current_loaded_failed_live_or_wrong_unit_never_uses_history(self) -> None:
        for key, value in [('Id','foreign'), ('LoadState','loaded'), ('ActiveState','failed'), ('SubState','exited'), ('MainPID','12')]:
            saved = dict(self.local.systemctl_state)
            self.local.systemctl_state[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.origin()
            self.local.systemctl_state = saved
        self.fixture.binding.assert_not_called()

    def test_guard_identity_process_or_runtime_mismatch_is_rejected(self) -> None:
        changes = [('source','/foreign'), ('revision','d' * 40), ('runtime_invocation','/foreign'),
                   ('runtime_invocation_sha256','0' * 64), ('producer_unit','foreign'), ('producer_pid',False),
                   ('producer_start_ticks','0')]
        for key, value in changes:
            saved = copy.deepcopy(self.fixture.record)
            self.fixture.record[key] = value
            self.fixture.save()
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.origin()
            self.fixture.record = saved
        self.fixture.save()
        self.fixture.binding.side_effect = ValueError('actual original source binding failed')
        with self.assertRaisesRegex(ValueError, 'original source binding'):
            self.origin()

    def test_failed_guardian_or_changed_seal_is_not_a_successful_observation(self) -> None:
        cases = [('worker','exit_status',True), ('worker','status','foreign'), ('seal','status','foreign'),
                 ('seal','producer_result',{}), ('seal','prunes',[{}]), ('seal','stopped',{'MainPID':'1','ActiveState':'inactive'}),
                 ('seal','terminal',{}), ('worker','producer',{})]
        for owner, key, value in cases:
            before = copy.deepcopy(getattr(self.fixture, owner))
            getattr(self.fixture, owner)[key] = value
            self.fixture.save()
            with self.subTest(owner=owner,key=key), self.assertRaises(ValueError):
                self.origin()
            setattr(self.fixture, owner, before)
        self.fixture.save()

    def test_journal_rejects_foreign_sender_boot_manager_unit_invocation_job_command_or_clock(self) -> None:
        changes = [(0,'_EXE','/tmp/systemd'),(0,'_COMM','other'),(0,'_UID','999999'),(0,'_SYSTEMD_UNIT','foreign'),
                   (0,'_SYSTEMD_USER_UNIT','foreign'),(0,'_BOOT_ID','3' * 32),(0,'USER_UNIT','foreign'),(0,'MESSAGE_ID','0' * 32),
                   (1,'USER_INVOCATION_ID','3' * 32),(1,'_PID','100'),(1,'JOB_RESULT','failed'),
                   (1,'JOB_TYPE','stop'),(1,'JOB_ID','999'),(1,'MESSAGE','foreign'),
                   (1,'__MONOTONIC_TIMESTAMP','6'),(3,'__MONOTONIC_TIMESTAMP','8'),
                   (0,'__REALTIME_TIMESTAMP','1'),(3,'__REALTIME_TIMESTAMP','1')]
        for index,key,value in changes:
            before = copy.deepcopy(self.local.journal_rows)
            self.local.journal_rows[index][key] = value
            with self.subTest(index=index,key=key), self.assertRaises(ValueError):
                self.origin()
            self.local.journal_rows = before
        for rows in [[], self.local.journal_rows[:-1], self.local.journal_rows + self.local.journal_rows, list(reversed(self.local.journal_rows))]:
            with self.subTest(rows=len(rows)), self.fixture.commands(), self.assertRaises(ValueError):
                EVIDENCE.recover(self.local.invocation,self.local.invocation_path,
                    lambda command, rows=rows: '\n'.join(json.dumps(row) for row in rows) if command[0]=='journalctl' else '\n'.join(f'{k}={v}' for k,v in self.local.systemctl_state.items()))

    def test_journal_command_suffix_and_creation_timezone_are_required(self) -> None:
        self.local.journal_rows[0]['MESSAGE'] = self.local.journal_rows[0]['MESSAGE'][:-3] + '???'
        with self.assertRaisesRegex(ValueError, 'description is missing'):
            self.origin()
        self.local.journal_rows = self.fixture.events()
        value = self.origin()['terminal_evidence']['journal']
        value['created_at'] = '2026-11-15T00:00:00'
        with self.assertRaisesRegex(ValueError, 'no timezone'):
            EVIDENCE.journal_proof(value, self.local.unit, 7)
        value['created_at'] = '2026-11-14T23:59:59+00:00'
        with self.assertRaisesRegex(ValueError, 'predates'):
            EVIDENCE.journal_proof(value, self.local.unit, 7)

    def test_receipt_validation_requires_its_terminal_companion(self) -> None:
        with self.fixture.commands():
            MAIN.check(self.local.args)
        receipt = json.loads(Path(self.local.args.receipt).read_text())
        receipt['local_subject']['terminal_evidence']['kind'] = 'foreign'
        receipt['local_subject_after'] = copy.deepcopy(receipt['local_subject'])
        with self.assertRaisesRegex(ValueError, 'terminal evidence'):
            LOCAL.validate_receipt(receipt, self.local.reference, self.local.platform)

    def test_journal_matching_description_cannot_name_another_command(self) -> None:
        self.local.journal_rows[1]['MESSAGE'] = self.local.journal_rows[1]['MESSAGE'].replace('--skip-manifest','--gates-only')
        with self.assertRaisesRegex(ValueError, 'another driver'):
            self.origin()

    def test_missing_or_mutated_terminal_receipt_fields_fail_validation(self) -> None:
        original = self.origin()
        for path,value in [(('terminal_evidence',),None),(('unit','observation_source'),'foreign'),
                           (('terminal_evidence','kind'),'foreign'),
                           (('terminal_evidence','guard_directory'),'relative'),
                           (('terminal_evidence','guard_hashes'),{}),
                           (('terminal_evidence','journal','events',1,'JOB_RESULT'),'failed')]:
            changed = copy.deepcopy(original)
            target: Any = changed
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = value
            with self.subTest(path=path),self.assertRaises(ValueError):
                EVIDENCE.validate(changed)
        EVIDENCE.validate(original)

    def test_guard_prune_bytes_and_path_must_remain_bound(self) -> None:
        directory=self.fixture.directory/'prune-1'
        directory.mkdir()
        path=directory/'proof.json'
        path.write_text('{}')
        row={'directory':str(directory),'proof_file':str(path),'proof_sha256':LOCAL.fingerprint(path)}
        self.fixture.worker['prunes']=[row]
        self.fixture.seal['prunes']=[row]
        self.fixture.save()
        self.origin()
        path.write_text('{"changed":true}')
        with self.assertRaisesRegex(ValueError,'proof changed'):
            self.origin()
        row['proof_sha256']=LOCAL.fingerprint(path)
        row['directory']=str(directory.parent)
        self.fixture.save()
        with self.assertRaisesRegex(ValueError,'path differs'):
            self.origin()


if __name__ == '__main__':
    unittest.main()
