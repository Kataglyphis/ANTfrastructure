"""Observe current QA use; these checks neither lock resources nor predict future activity."""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any

from host_commands import checked_output
from source_ci.common import require


def command_json(command: list[str], lines: bool = False) -> list[dict[str, Any]]:
    result = subprocess.run(command, capture_output=True, text=True, check=False, timeout=30)
    require(result.returncode == 0 and not result.stderr.strip(), f"Observation failed: {command[0]}")
    rows = [json.loads(line) for line in result.stdout.splitlines() if line] if lines else json.loads(result.stdout)
    require(isinstance(rows, list) and all(isinstance(row, dict) for row in rows), "Malformed observation records")
    return rows


def idle_units() -> list[dict[str, str]]:
    rows = command_json(['systemctl', '--user', 'list-units', '--all', '--output=json', '--no-pager'])
    states = []
    for row in rows:
        name = row.get('unit')
        require(isinstance(name, str), 'Malformed unit identity')
        name = str(name)
        if not name.startswith(('webgpu-', 'rebuild-sequence-', 'hub-preflight-')):
            continue
        require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:@-]*\.service', name), 'Unexpected build unit name')
        fields = 'Id,ActiveState,SubState,MainPID,ControlPID'
        raw = checked_output(['systemctl', '--user', 'show', name, '--property=' + fields])
        state = dict(line.split('=', 1) for line in raw.splitlines())
        require(set(state) == set(fields.split(',')) and state['Id'] == name, 'Incomplete unit observation')
        terminal = {('inactive', 'dead'), ('failed', 'failed'), ('active', 'exited')}
        require((state['ActiveState'], state['SubState']) in terminal
                and state['MainPID'] == state['ControlPID'] == '0', 'A build or QA unit is active')
        states.append(state)
    return states


def idle_engines(paths: list[Path], engine: str) -> dict[str, int]:
    rows = command_json([engine, 'ps', '-a', '--no-trunc', '--format', '{{json .}}'], lines=True)
    for row in rows:
        require(re.fullmatch(r'[0-9a-f]{64}', str(row.get('ID', ''))), 'Truncated container identity')
        status = row.get('Status')
        require(isinstance(status, str) and (status == 'Created' or status.startswith(('Exited ', 'Dead'))),
                'An engine container is active or unknown')
        require(not any(str(path.parent.parent) in json.dumps(row) for path in paths), 'A container references a QA source')
    address = f'unix:///run/user/{os.getuid()}/buildkit/buildkitd.sock'
    records = command_json(['buildctl', '--addr', address, 'du', '--format', '{{json .}}'])
    require(all(type(row.get('inUse')) is bool for row in records), 'Unknown BuildKit use state')
    require(not any(row['inUse'] for row in records), 'BuildKit has in-use records')
    return {'containers': len(rows), 'buildkit_records': len(records)}


def unescape_proc(value: bytes) -> bytes:
    return re.sub(rb'\\([0-7]{3})', lambda match: bytes([int(match[1], 8)]), value)


def idle_mounts(paths: list[Path], proc_root: Path) -> None:
    for line in (proc_root / 'self/mountinfo').read_bytes().splitlines():
        fields = line.split()
        require(len(fields) >= 6, 'Malformed mount observation')
        mount = Path(os.fsdecode(unescape_proc(fields[4])))
        require(not any(mount.is_relative_to(path) for path in paths), 'A selected QA tree contains a mount')


def process_evidence(process: Path) -> bytes:
    arguments = (process / 'cmdline').read_bytes()
    if not arguments:
        return b''
    data = arguments + b'\0' + unescape_proc((process / 'maps').read_bytes())
    for name in ('cwd', 'exe'):
        data += b'\0' + os.fsencode((process / name).readlink())
    for descriptor in (process / 'fd').iterdir():
        try:
            data += b'\0' + os.fsencode(descriptor.readlink())
        except FileNotFoundError:
            pass
    return data


def idle_processes(paths: list[Path], proc_root: Path) -> int:
    inspected = 0
    roots = [os.fsencode(path.parent.parent) for path in paths]
    for process in proc_root.iterdir():
        if not process.name.isdecimal():
            continue
        try:
            if process.stat().st_uid != os.getuid():
                continue
            data = process_evidence(process)
        except FileNotFoundError:
            require(not process.exists(), 'A live process has incomplete use observations')
            continue
        require(not any(root in data for root in roots), f'QA source in use by PID {process.name}')
        inspected += 1
    return inspected


def observe_usage(paths: list[Path], engine: str, proc_root: Path = Path('/proc')) -> dict[str, Any]:
    units = idle_units()
    engines = idle_engines(paths, engine)
    idle_mounts(paths, proc_root)
    processes = idle_processes(paths, proc_root)
    return {'units': units, **engines, 'user_processes_inspected': processes,
            'scope': 'Current known units, engines, user processes and mounts; no concurrent-writer or future-idle guarantee.'}
