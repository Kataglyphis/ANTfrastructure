"""Independent journal and sealed-observer doubles; no real service, source qualification or image proof."""

from __future__ import annotations

import datetime
import json
import os
import shlex
from collections.abc import Generator
from contextlib import ExitStack, contextmanager
from typing import Any
from unittest import mock

from image_acceptance_local_fixture import LOCAL, LocalFixture

EVIDENCE = LOCAL.terminal_evidence
BOOT = '1' * 32
EVENTS = ('7d4958e842da4a758f6c1cdc7b36dcc5', '39f53479d3a045ac8e11786248231fbf',
          'de5b426a63be47a7b6ac3eaac82e2f6f', '9d1aaa27d60140bd96365438aad20286')


class TerminalFixture:
    def __init__(self, local: LocalFixture) -> None:
        self.local = local
        local.invocation['created_at'] = '2026-11-15T00:00:00+00:00'
        local.save()
        local.terminal.side_effect = AssertionError('Producer unit is missing')
        local.systemctl_state = {'Id':local.unit, 'LoadState':'not-found', 'ActiveState':'inactive', 'SubState':'dead', 'MainPID':'0'}
        self.directory = local.directory.with_name(local.directory.name + '-storage-guard')
        self.directory.mkdir()
        self.record: dict[str, Any] = {'source':str(local.host), 'revision':local.host_head, 'runtime_invocation':str(local.invocation_path),
                       'runtime_invocation_sha256':LOCAL.fingerprint(local.invocation_path), 'producer_unit':local.unit,
                       'producer_pid':123, 'producer_start_ticks':'456', 'unit':'webgpu-safe-prune-runtime-' + local.arch + '-99999999-1.service'}
        producer = dict(local.terminal.return_value, ExecMainExitTimestampMonotonic='7')
        terminal = dict(producer, Id=self.record['unit'])
        self.worker: dict[str, Any] = {'status':'observed-producer-terminal', 'exit_status':0, 'producer':producer, 'prunes':[]}
        self.seal: dict[str, Any] = {'status':'completed-storage-observation-only', 'producer_result':producer, 'terminal':terminal,
                     'stopped':{'MainPID':'0','ActiveState':'inactive'}, 'prunes':[]}
        self.binding = mock.Mock()
        self.journal = self.events()
        local.journal_rows = self.journal
        self.save()

    def events(self) -> list[dict[str, Any]]:
        base = int(datetime.datetime(2026, 11, 15, tzinfo=datetime.UTC).timestamp() * 1000000)
        rows = []
        command = shlex.join(self.local.invocation['command'][-11:])
        for index, identifier in enumerate(EVENTS):
            suffix = '.' if index % 2 else '...'
            row = {'USER_UNIT':self.local.unit, 'USER_INVOCATION_ID':'2' * 32, 'MESSAGE_ID':identifier,
                   'JOB_ID':str(100 + index // 2), 'JOB_TYPE':'start' if index < 2 else 'stop',
                   '_EXE':'/usr/lib/systemd/systemd', '_COMM':'systemd', '_UID':str(os.getuid()), '_PID':'99',
                   '_SYSTEMD_UNIT':f'user@{os.getuid()}.service', '_SYSTEMD_USER_UNIT':'init.scope', '_BOOT_ID':BOOT,
                   '__REALTIME_TIMESTAMP':str(base + index + 1), '__MONOTONIC_TIMESTAMP':str((1, 8, 9, 10)[index]),
                   'MESSAGE':'Fixture lifecycle: [systemd-run] ' + command + suffix}
            if index % 2:
                row['JOB_RESULT'] = 'done'
            rows.append(row)
        return rows

    def save(self) -> None:
        for name, value in [('invocation.json',self.record), ('worker-result.json',self.worker), ('proof-stopped.json',self.seal)]:
            (self.directory / name).write_text(json.dumps(value))

    @contextmanager
    def commands(self) -> Generator[None, None, None]:
        with self.local.commands(), ExitStack() as stack:
            stack.enter_context(mock.patch.object(EVIDENCE, 'boot_id', return_value=BOOT))
            stack.enter_context(mock.patch.object(EVIDENCE, 'guard_source', return_value={'source_binding':self.binding}))
            yield
