"""Recover an unloaded runtime from a sealed observer and fresh journal; no receipt authentication or inference proof."""

from __future__ import annotations

import datetime
import json
import os
import re
import runpy
import shlex
import uuid
from collections.abc import Callable
from itertools import pairwise
from pathlib import Path
from typing import Any

from source_ci.common import fingerprint, read, require

KIND = 'sealed-guardian-and-live-journal'
OBSERVATION = 'sealed-storage-guardian'
HASH = re.compile(r'[0-9a-f]{64}\Z')
IDS = ('7d4958e842da4a758f6c1cdc7b36dcc5', '39f53479d3a045ac8e11786248231fbf',
       'de5b426a63be47a7b6ac3eaac82e2f6f', '9d1aaa27d60140bd96365438aad20286')
FIELDS = ('USER_UNIT', 'USER_INVOCATION_ID', 'MESSAGE_ID', 'JOB_ID', 'JOB_TYPE', 'JOB_RESULT', 'UNIT_RESULT',
          '_EXE', '_COMM', '_UID', '_PID', '_SYSTEMD_UNIT', '_SYSTEMD_USER_UNIT', '_BOOT_ID',
          '__REALTIME_TIMESTAMP', '__MONOTONIC_TIMESTAMP', 'MESSAGE')


def _object(path: Path) -> dict[str, Any]:
    value = read(path)
    require(isinstance(value, dict), 'Terminal evidence must be an object')
    return value


def _positive(value: Any) -> int:
    require(isinstance(value, str) and value.isdecimal() and int(value) > 0, 'Invalid terminal clock or process identity')
    return int(value)


def successful_unit(value: Any, unit: str) -> dict[str, Any]:
    require(isinstance(value, dict), 'Terminal unit must be an object')
    expected = {'Id':unit, 'LoadState':'loaded', 'ActiveState':'active', 'SubState':'exited',
                'MainPID':'0', 'ExecMainStatus':'0', 'Result':'success'}
    require(all(value.get(key) == item for key, item in expected.items()), 'Retained unit was not terminal successful')
    _positive(value.get('ExecMainExitTimestampMonotonic'))
    return value


def _prune_proofs(rows: Any, directory: Path) -> None:
    require(isinstance(rows, list), 'Guardian cleanup evidence is malformed')
    for row in rows:
        require(isinstance(row, dict), 'Guardian cleanup entry is malformed')
        path = Path(row['proof_file']).resolve(strict=True)
        require(path.is_relative_to(directory) and path.parent == Path(row['directory']).resolve()
                and path.name in {'proof.json', 'skip-proof.json'}, 'Guardian cleanup path differs')
        require(fingerprint(path) == row['proof_sha256'], 'Guardian cleanup proof changed')


def guard_source(path: Path) -> dict[str, Any]:
    return runpy.run_path(str(path / 'linux/scripts/runtime_storage_guard.py'))


def _retained(invocation: dict[str, Any], path: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    directory = path.parent.with_name(path.parent.name + '-storage-guard').resolve(strict=True)
    record = _object(directory / 'invocation.json')
    host = Path(invocation['engine_wrapper']).resolve(strict=True).parents[2]
    require(record['source'] == str(host) and record['revision'] == invocation['host_tools_revision'], 'Guardian host differs')
    require(record['runtime_invocation'] == str(path.resolve()) and record['runtime_invocation_sha256'] == fingerprint(path)
            and record['producer_unit'] == invocation['unit'], 'Guardian watched another runtime')
    require(type(record['producer_pid']) is int and record['producer_pid'] > 0, 'Guardian process binding is missing')
    _positive(record.get('producer_start_ticks'))
    guard_source(host)['source_binding'](record)
    worker, proof = [_object(directory / name) for name in ('worker-result.json', 'proof-stopped.json')]
    require(worker['status'] == 'observed-producer-terminal' and type(worker['exit_status']) is int
            and worker['exit_status'] == 0 and proof['status'] == 'completed-storage-observation-only', 'Guardian did not finish successfully')
    producer = successful_unit(worker['producer'], invocation['unit'])
    successful_unit(proof['terminal'], record['unit'])
    require(proof['stopped'].get('MainPID') == '0' and proof['stopped'].get('ActiveState') == 'inactive', 'Guardian is not stopped')
    require(proof['producer_result'] == producer and proof['prunes'] == worker['prunes'], 'Guardian seal differs from its worker')
    _prune_proofs(proof['prunes'], directory)
    evidence = {'kind':KIND, 'guard_directory':str(directory),
                'guard_hashes':{name:fingerprint(directory / name) for name in ('invocation.json', 'worker-result.json', 'proof-stopped.json')}}
    return dict(producer, observation_source=OBSERVATION), evidence


def _sender(rows: list[dict[str, Any]], unit: str, boot: str, uid: int) -> None:
    require([row.get('MESSAGE_ID') for row in rows] == list(IDS), 'Journal lifecycle is missing, duplicated or reused')
    expected = {'USER_UNIT':unit, '_BOOT_ID':boot, '_COMM':'systemd', '_UID':str(uid),
                '_SYSTEMD_UNIT':f'user@{uid}.service', '_SYSTEMD_USER_UNIT':'init.scope'}
    for row in rows:
        require(all(row.get(key) == value for key, value in expected.items())
                and row.get('_EXE') in {'/usr/lib/systemd/systemd', '/lib/systemd/systemd'}, 'Journal sender or unit differs')
    identity = rows[0].get('USER_INVOCATION_ID')
    require(isinstance(identity, str) and re.fullmatch(r'[0-9a-f]{32}', identity) is not None
            and all(row.get('USER_INVOCATION_ID') == identity for row in rows), 'Journal invocation differs')
    require(len({row.get('_PID') for row in rows}) == 1, 'Journal manager PID changed')
    _positive(rows[0].get('_PID'))


def _jobs(rows: list[dict[str, Any]], driver: list[str]) -> None:
    for index, row in enumerate(rows):
        require(row.get('JOB_TYPE') == ('start' if index < 2 else 'stop'), 'Journal job type differs')
        require(row.get('JOB_RESULT') == ('done' if index % 2 else None), 'Journal job failed or result differs')
        require(row.get('UNIT_RESULT') in (None, 'success'), 'Journal unit result failed')
        _positive(row.get('JOB_ID'))
        suffix = '.' if index % 2 else '...'
        message = row.get('MESSAGE')
        if not (isinstance(message, str) and message.count('[systemd-run] ') == 1 and message.endswith(suffix)):
            raise ValueError('Journal command description is missing')
        body = message.split('[systemd-run] ', 1)[1][:-len(suffix)]
        require(shlex.split(body) == driver, 'Journal ran another driver')
    require(rows[0]['JOB_ID'] == rows[1]['JOB_ID'] and rows[2]['JOB_ID'] == rows[3]['JOB_ID'], 'Journal job identities differ')


def _journal_inputs(value: dict[str, Any]) -> tuple[list[dict[str, Any]], str, int, list[str]]:
    rows, boot, uid, driver = value.get('events'), value.get('boot_id'), value.get('uid'), value.get('driver')
    if not (isinstance(rows, list) and all(isinstance(row, dict) for row in rows)):
        raise ValueError('Journal records are malformed')
    if not (isinstance(boot, str) and re.fullmatch(r'[0-9a-f]{32}', boot) is not None
            and type(uid) is int and uid >= 0):
        raise ValueError('Journal boot or owner is malformed')
    if not (isinstance(driver, list) and len(driver) == 11 and all(isinstance(word, str) and word for word in driver)):
        raise ValueError('Journal driver is malformed')
    return rows, boot, uid, driver


def journal_proof(value: dict[str, Any], unit: str, exit_timestamp: int) -> dict[str, Any]:
    rows, boot, uid, driver = _journal_inputs(value)
    _sender(rows, unit, boot, uid)
    _jobs(rows, driver)
    clocks = [_positive(row.get('__MONOTONIC_TIMESTAMP')) for row in rows]
    require(type(exit_timestamp) is int and clocks[0] <= exit_timestamp <= clocks[1]
            and clocks[0] < clocks[1] < clocks[2] < clocks[3], 'Journal and actual exit clocks differ')
    created = datetime.datetime.fromisoformat(value['created_at'])
    require(created.tzinfo is not None, 'Runtime creation time has no timezone')
    wall = [_positive(row.get('__REALTIME_TIMESTAMP')) for row in rows]
    created_us = int(created.timestamp() * 1000000)
    require(wall[0] - clocks[0] <= created_us <= wall[0] and all(a < b for a, b in pairwise(wall)), 'Journal predates or reorders the runtime')
    return {'boot_id':boot, 'uid':uid, 'driver':driver, 'created_at':value['created_at'],
            'events':[{key:row[key] for key in FIELDS if key in row} for row in rows]}


def boot_id() -> str:
    return uuid.UUID(Path('/proc/sys/kernel/random/boot_id').read_text().strip()).hex


def recover(invocation: dict[str, Any], path: Path, query: Callable[[list[str]], str]) -> dict[str, Any]:
    unit = invocation['unit']
    raw = query(['systemctl', '--user', 'show', unit, '--property=Id,LoadState,ActiveState,SubState,MainPID'])
    state = dict(line.split('=', 1) for line in raw.splitlines() if '=' in line)
    require(state == {'Id':unit, 'LoadState':'not-found', 'ActiveState':'inactive', 'SubState':'dead', 'MainPID':'0'}, 'Only a genuinely unloaded runtime may recover evidence')
    producer, evidence = _retained(invocation, path)
    boot = boot_id()
    raw = query(['journalctl', '--user', '--no-pager', '--output=json', '--boot=' + boot, 'USER_UNIT=' + unit])
    rows = [json.loads(line) for line in raw.splitlines() if line.strip()]
    journal = {'events':rows, 'boot_id':boot, 'uid':os.getuid(), 'driver':invocation['command'][-11:], 'created_at':invocation['created_at']}
    stamp = _positive(producer['ExecMainExitTimestampMonotonic'])
    evidence['journal'] = journal_proof(journal, unit, stamp)
    return {'unit':producer, 'exit_timestamp_monotonic':stamp, 'terminal_evidence':evidence}


def validate(origin: dict[str, Any]) -> None:
    unit, evidence = origin['unit'], origin.get('terminal_evidence')
    if unit.get('observation_source') is None:
        require(evidence is None, 'Unexpected terminal evidence on a live observation')
        return
    if not (unit.get('observation_source') == OBSERVATION and isinstance(evidence, dict)
            and evidence.get('kind') == KIND):
        raise ValueError('Retained terminal evidence is missing or unknown')
    require(isinstance(evidence.get('guard_directory'), str) and Path(evidence['guard_directory']).is_absolute(), 'Guardian evidence path is not absolute')
    hashes = evidence.get('guard_hashes')
    require(isinstance(hashes, dict) and set(hashes) == {'invocation.json', 'worker-result.json', 'proof-stopped.json'}
            and all(isinstance(value, str) and HASH.fullmatch(value) for value in hashes.values()), 'Guardian evidence hashes are missing')
    require(isinstance(evidence.get('journal'), dict)
            and journal_proof(evidence['journal'], unit['Id'], origin['exit_timestamp_monotonic']) == evidence['journal'], 'Terminal journal evidence changed')
