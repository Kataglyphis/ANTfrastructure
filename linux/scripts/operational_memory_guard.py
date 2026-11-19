"""Observe controller absence; names and process arguments authenticate neither writers nor future inactivity."""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any

from host_commands import checked_output
from source_ci.common import require, timestamp

PROC = Path('/proc')
MARKERS = ('storage-guard', 'safe-prune')
FIELDS = ('Id', 'LoadState', 'ActiveState', 'SubState', 'MainPID', 'ControlPID')


def controller_name(value: str) -> bool:
    return any(marker in value.replace('_', '-') for marker in MARKERS)


def unit_state(row: Any) -> dict[str, str]:
    require(isinstance(row, dict), 'Malformed controller unit entry')
    name = row.get('unit')
    require(isinstance(name, str) and re.fullmatch(r'[A-Za-z0-9_.:@-]+\.service', name)
            and controller_name(name), 'Unexpected controller unit identity')
    raw = checked_output(['systemctl', '--user', 'show', name, '--no-pager', '--property=' + ','.join(FIELDS)])
    lines = raw.splitlines()
    require(len(lines) == len(FIELDS) and all('=' in line for line in lines), 'Incomplete controller properties')
    state = dict(line.split('=', 1) for line in lines)
    require(set(state) == set(FIELDS) and state['Id'] == name and state['LoadState'] == 'loaded',
            'Controller identity or load state changed')
    require(state['MainPID'].isdecimal() and state['ControlPID'].isdecimal(), 'Malformed controller PID')
    require(all(row.get(key) == state[field] for key, field in
                (('load', 'LoadState'), ('active', 'ActiveState'), ('sub', 'SubState'))),
            'Controller state changed during observation')
    return state


def controller_units() -> list[dict[str, str]]:
    raw = checked_output(['systemctl', '--user', 'list-units', '--all', '--output=json', '--no-pager',
                          '*storage-guard*', '*safe-prune*'])
    rows = json.loads(raw)
    require(isinstance(rows, list), 'Malformed controller unit list')
    states = [unit_state(row) for row in rows]
    require(len({state['Id'] for state in states}) == len(states), 'Duplicate controller unit')
    return states


def controller_processes() -> tuple[int, list[int]]:
    inspected = 0
    controllers = []
    for process in PROC.iterdir():
        if not process.name.isdecimal() or int(process.name) == os.getpid():
            continue
        try:
            arguments = process.joinpath('cmdline').read_bytes().split(b'\0')
        except FileNotFoundError:
            continue
        inspected += 1
        if any(controller_name(argument.decode('utf-8', errors='replace')) for argument in arguments):
            controllers.append(int(process.name))
    return inspected, controllers


def controller_absence() -> dict[str, Any]:
    states = controller_units()
    terminal = {('inactive', 'dead'), ('failed', 'failed'), ('active', 'exited')}
    require(all((state['ActiveState'], state['SubState']) in terminal
                and state['MainPID'] == state['ControlPID'] == '0' for state in states),
            'A storage controller is live or has an unknown state')
    inspected, processes = controller_processes()
    require(not processes, 'Storage controller process IDs are live: ' + ','.join(map(str, processes)))
    return {'observed_at': timestamp(), 'units': states, 'inspected_processes': inspected,
            'matching_controller_processes': processes, 'scope': __doc__}
