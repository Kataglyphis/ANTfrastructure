#!/usr/bin/env python3
"""Copy four stable live Ninja/CMake inputs; no source authentication, complete phase, linkage, licence or image acceptance."""

from __future__ import annotations

import argparse
import datetime
import json
import runpy
import shutil
import stat
from pathlib import Path
from typing import TYPE_CHECKING

from cache_capture_profile import PHASE_MARKERS
from native_oci_layout import sha
from native_oci_seed import plain_directory
from proof_commands import checked_run

if TYPE_CHECKING:
    from proof_types import Json

FILES = ('CMakeCache.txt', 'build.ninja', 'CMakeFiles/rules.ninja', 'CMakeFiles/CMakeConfigureLog.yaml')
MAX_FILE = 32 * 1024 * 1024
MAX_TOTAL = 64 * 1024 * 1024
START_TICKS = runpy.run_path(str(Path(__file__).with_name('capture-live-sccache-log.py')))['start_ticks']


def file_hashes(root: Path) -> dict[str, str]:
    total = 0
    hashes = {}
    for name in FILES:
        path = root / name
        assert not any((root / parent).is_symlink() for parent in [Path(name),*Path(name).parents] if str(parent) != '.'), 'Configure input has a symlink component'
        info = path.lstat()
        assert stat.S_ISREG(info.st_mode) and 0 < info.st_size <= MAX_FILE, 'Configure input is missing, empty, nonregular or oversized'
        total += info.st_size
        assert total <= MAX_TOTAL, 'Configure input set exceeds the byte bound'
        hashes[name] = sha(path)
    return hashes


def live_subject(invocation: Path, pid: int, process: Path | None) -> tuple[Json, dict[str, str], Path, str, str]:
    assert pid > 1, 'Invalid source process'
    inv = json.loads(invocation.read_text())
    raw = checked_run(['systemctl','--user','show',inv['unit'],'--property=Id,LoadState,ActiveState,MainPID']).stdout
    unit = dict(line.split('=',1) for line in raw.splitlines() if '=' in line)
    assert unit['Id'] == inv['unit'] and unit['LoadState'] == 'loaded' and unit['ActiveState'] in {'active','activating'} and int(unit['MainPID']) > 0, 'Actual producer must be live'
    process = process if process is not None else Path(f'/proc/{pid}')
    ticks = START_TICKS(process)
    command = (process / 'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace').strip()
    assert PHASE_MARKERS['migraphx'] in command, 'Process does not match the normal MIGraphX build'
    return inv,unit,process,ticks,command


def snapshot(invocation: Path, pid: int, relative: Path, output: Path, process: Path | None = None) -> Json:
    assert not relative.is_absolute() and '..' not in relative.parts, 'Invalid relative build path'
    assert relative.parts[:2] == ('tmp','migraphx-source-stack'), 'Only the normal MIGraphX work tree is supported'
    inv,unit,process,ticks,command = live_subject(invocation,pid,process)
    root = process / 'root' / relative
    assert root.is_dir() and not any((process / 'root' / parent).is_symlink() for parent in [relative,*relative.parents] if str(parent) != '.'), 'Build path must have regular directory components'
    plain_directory(output.parent)
    assert not output.resolve().is_relative_to(root.resolve()) and not root.resolve().is_relative_to(output.resolve()), 'Source and snapshot roots overlap'
    before = file_hashes(root)
    output.mkdir(mode=0o700)
    for name in FILES:
        target = output / name
        target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(root / name,target)
    assert file_hashes(root) == before == file_hashes(output), 'Source or copied configure bytes changed'
    assert START_TICKS(process) == ticks, 'Source process identity changed during snapshot'
    record: Json = {'status':'passed-stable-live-configure-copy-only', 'observed_at':datetime.datetime.now(datetime.UTC).isoformat(),
              'producer_unit':inv['unit'], 'producer_unit_state':unit, 'invocation':str(invocation.resolve()), 'invocation_sha256':sha(invocation),
              'source_revision':inv['source_revision'], 'pid':pid, 'pid_start_ticks':ticks, 'command':command,
              'source_root':str(root), 'output':str(output.resolve()), 'sha256':before, 'source_hashes_unchanged_across_copy':True,
              'producer_changed':False, 'image_acceptance':False, 'scope':__doc__}
    with (output / 'observation.json').open('x') as stream:
        stream.write(json.dumps(record,indent=2) + '\n')
    return record


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--invocation',required=True,type=Path)
    parser.add_argument('--pid',required=True,type=int)
    parser.add_argument('--relative-root',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    args = parser.parse_args()
    record = snapshot(args.invocation,args.pid,args.relative_root,args.output)
    print(json.dumps({'status':record['status'],'files':len(record['sha256']),'output':record['output']}))


if __name__ == '__main__':
    main()
