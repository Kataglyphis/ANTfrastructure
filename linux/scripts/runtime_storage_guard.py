"""Watch one existing runtime and use canonical layer cleanup; no build, image, licence or inference acceptance."""

from __future__ import annotations

import hashlib
import json
import os
import re
import runpy
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from host_commands import checked_output
from image_acceptance_local import local_api
from source_ci.common import fingerprint, read, require, save, timestamp

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
HOST = ROOT / 'linux/host-config'
CONTROLLER = HOST / 'autonomous-safe-prune.py'
CANONICAL = HOST / 'prune-safe.sh'
KEEP_GB = 100
REQUIRED_BYTES = 193273528320
TIMEOUT = 21600
GUARD_UNIT = re.compile(r'webgpu-safe-prune-runtime-(amd64|arm64|riscv64)-[0-9-]+\.service')
UNIT_API = runpy.run_path(str(HERE / 'seal-mutation-unit.py'))['unit_state']
TERMINAL = runpy.run_path(str(HERE / 'watch-build-units.py'))['terminal']


def workers() -> list[Path]:
    return [Path(__file__), HERE / 'launch-runtime-storage-guard.py', HERE / 'host_commands.py',
            HERE / 'image_acceptance_local.py', HERE / 'source_ci/common.py',
            HERE / 'seal-mutation-unit.py', HERE / 'watch-build-units.py',
            HERE / 'local-proof/capture-live-sccache-log.py', HERE / 'local-proof/cache_capture_profile.py',
            HOST / 'autonomous-safe-prune.py', HOST / 'prune-safe.sh',
            HOST / 'verify-safe-prune.py', HOST / 'nerdctl-full-state.py', HERE / '01-core/disk-guard.sh']


def source_binding(record: dict[str, Any]) -> None:
    require(isinstance(record.get('unit'), str) and GUARD_UNIT.fullmatch(record['unit']), 'Storage guardian unit identity differs')
    require(record['source'] == str(ROOT), 'Storage guardian belongs to another checkout')
    require(checked_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD']).strip() == record['revision'], 'Storage guardian revision changed')
    require(not checked_output(['git', '-C', str(ROOT), 'status', '--porcelain']).strip(), 'Commit storage guardian tools before use')
    require(record['workers_sha256'] == {str(path):fingerprint(path) for path in workers()}, 'Storage guardian worker closure changed')
    require(fingerprint(Path(record['authorization'])) == record['authorization_sha256'], 'Storage authorization changed')
    require(fingerprint(Path(record['runtime_invocation'])) == record['runtime_invocation_sha256'], 'Watched runtime invocation changed')
    require(type(record['keep_gb']) is int and record['keep_gb'] == KEEP_GB and type(record['timeout_seconds']) is int and record['timeout_seconds'] == TIMEOUT, 'Storage guardian profile changed')


def producer_state(record: dict[str, Any]) -> dict[str, str]:
    state = UNIT_API(record['producer_unit'])
    require(state.get('Id') == record['producer_unit'] and state.get('LoadState') == 'loaded', 'Watched runtime unit is missing')
    if TERMINAL(state):
        return state
    require(state.get('MainPID') == str(record['producer_pid']) and state.get('ActiveState') in {'active', 'activating'}, 'Watched runtime PID changed')
    process = Path('/proc') / str(record['producer_pid'])
    require(local_api('capture-live-sccache-log').start_ticks(process) == record['producer_start_ticks'], 'Watched runtime process identity changed')
    return state


def candidate(records: list[dict[str, Any]]) -> tuple[str, int]:
    regular = [row for row in records if row.get('recordType', 'regular') == 'regular']
    for row in regular:
        require(type(row.get('size')) is int and row['size'] >= 0 and isinstance(row.get('id'), str) and bool(row['id']), 'Malformed regular cache record')
        require(type(row.get('inUse')) is bool and type(row.get('shared')) is bool, 'Malformed regular cache ownership')
    total = sum(row['size'] for row in regular)
    unused = sorted((row['id'], row['size']) for row in regular if not row['inUse'] and not row['shared'] and row['size'] > 0)
    amount = min(max(0, total - KEEP_GB * 1000000000), sum(size for _, size in unused))
    key = hashlib.sha256(json.dumps({'unused':unused, 'estimated_bytes':amount}).encode()).hexdigest() if amount else ''
    return key, amount


def reclaim(directory: Path, record: dict[str, Any], index: int, producer: dict[str, str]) -> dict[str, Any]:
    destination = directory / ('prune-' + str(index))
    require(not destination.exists() and not destination.is_symlink(), 'Preserve an earlier storage cleanup')
    destination.mkdir()
    save(destination / 'invocation.json', {'created_at':timestamp(), 'keep_gb':KEEP_GB, 'idle_store_required':False,
         'canonical_script_sha256':fingerprint(CANONICAL), 'controller_unit':record['unit'], 'producer_state_at_dispatch':producer,
         'scope':'Synchronous canonical worker in the guardian control group; no separate cleanup service.'})
    command = [sys.executable, str(CONTROLLER), 'worker', '--directory', str(destination), '--unit', record['unit'],
               '--keep-gb', str(KEEP_GB), '--authorization', record['authorization']]
    with (destination / 'worker.log').open('xb') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=540, check=False)
    require(result.returncode == 0, 'Canonical storage cleanup failed: ' + str(result.returncode))
    proof_path = destination / 'proof.json'
    skipped = not proof_path.is_file()
    if skipped:
        proof_path = destination / 'skip-proof.json'
    proof = read(proof_path)
    if skipped:
        require(proof['status'] == 'skipped-reserve-already-sufficient' and proof['reclaim_performed'] is False and proof['free_bytes'] >= REQUIRED_BYTES and proof['canonical_free_gib'] >= 180, 'Canonical storage skip proof differs')
    else:
        require(proof['status'] == 'passed-authorized-canonical-layer-cleanup' and proof['keep_layer_gb'] == KEEP_GB, 'Canonical storage cleanup proof differs')
    return {'directory':str(destination), 'proof_file':str(proof_path), 'proof_sha256':fingerprint(proof_path), 'skipped':skipped,
            'free_bytes_before':proof['free_bytes'] if skipped else proof['free_bytes_before'],
            'free_bytes_after':proof['free_bytes'] if skipped else proof['free_bytes_after']}


def finish(directory: Path, state: dict[str, str], prunes: list[dict[str, Any]]) -> int:
    failed = state.get('Result') != 'success' or state.get('ExecMainStatus') != '0'
    code = int(failed)
    save(directory / 'worker-result.json', {'status':'observed-producer-terminal', 'producer':state, 'exit_status':code,
         'prunes':prunes, 'observed_at':timestamp(), 'build_or_image_accepted':False})
    return code


def worker(directory: Path) -> int:
    record = read(directory / 'invocation.json')
    source_binding(record)
    os.environ['BUILDKIT_HOST'] = 'unix:///run/user/' + str(os.getuid()) + '/buildkit/buildkitd.sock'
    deadline = time.monotonic() + TIMEOUT
    seen: set[str] = set()
    prunes: list[dict[str, Any]] = []
    with (directory / 'observations.jsonl').open('x') as observations:
        while time.monotonic() < deadline:
            state = producer_state(record)
            if TERMINAL(state):
                return finish(directory, state, prunes)
            free = shutil.disk_usage(Path.home()).free
            key, amount = ('', 0)
            if free < REQUIRED_BYTES:
                key, amount = candidate(json.loads(checked_output(['buildctl', 'du', '--format', '{{json .}}'])))
            observations.write(json.dumps({'observed_at':timestamp(), 'free_bytes':free, 'candidate':key, 'estimated_bytes':amount}) + '\n')
            observations.flush()
            if key and key not in seen:
                source_binding(record)
                state = producer_state(record)
                if TERMINAL(state):
                    return finish(directory, state, prunes)
                action = reclaim(directory, record, len(prunes) + 1, state)
                prunes.append(action)
                if not action['skipped']:
                    seen.add(key)
            time.sleep(1)
    raise TimeoutError('Storage observation deadline reached; producer was not changed')


def launch(runtime_path: Path, directory: Path, unit: str, authorization: Path) -> None:
    require(GUARD_UNIT.fullmatch(unit), 'Explicit bounded storage guardian unit required')
    require(UNIT_API(unit).get('LoadState') == 'not-found', 'Preserve an existing storage guardian unit')
    require(not directory.exists() and not directory.is_symlink(), 'Preserve previous storage observations')
    directory = directory.resolve()
    runtime_path, authorization = runtime_path.resolve(strict=True), authorization.resolve(strict=True)
    runtime = read(runtime_path)
    require(runtime.get('stage') == 'runtime' and type(runtime.get('launch_status')) is int and runtime['launch_status'] == 0, 'Actual runtime launch required')
    arch = runtime.get('target_arch')
    require(arch in {'amd64', 'arm64', 'riscv64'}, 'Supported ordinary runtime architecture required')
    require(re.fullmatch(r'webgpu-normal-runtime-' + arch + r'-[0-9-]+\.service', runtime['unit']), 'Ordinary runtime unit required')
    require('agents may run the existing \x60linux/host-config/prune-safe.sh\x60 autonomously' in authorization.read_text(), 'Standing canonical cleanup authorization required')
    state = UNIT_API(runtime['unit'])
    require(state.get('Id') == runtime['unit'] and state.get('LoadState') == 'loaded' and state.get('ActiveState') in {'active', 'activating'}, 'Runtime is not live')
    require(not TERMINAL(state) and state.get('MainPID', '').isdigit() and int(state['MainPID']) > 0, 'Runtime already ended')
    process = Path('/proc') / state['MainPID']
    require((process / 'cmdline').read_bytes().rstrip(b'\0').split(b'\0') == [word.encode() for word in runtime['command'][-11:]], 'Runtime process command differs')
    temporary = Path.home() / '.cache' / unit.removesuffix('.service')
    require(not temporary.exists() and all(not (path / '.git').exists() for path in [temporary, *temporary.parents]), 'Storage guardian TMPDIR must be fresh and outside Git')
    record = {'unit':unit, 'source':str(ROOT), 'revision':checked_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD']).strip(),
              'workers_sha256':{str(path):fingerprint(path) for path in workers()}, 'runtime_invocation':str(runtime_path),
              'runtime_invocation_sha256':fingerprint(runtime_path), 'producer_unit':runtime['unit'], 'producer_pid':int(state['MainPID']),
              'producer_start_ticks':local_api('capture-live-sccache-log').start_ticks(process), 'keep_gb':KEEP_GB,
              'timeout_seconds':TIMEOUT, 'authorization':str(authorization), 'authorization_sha256':fingerprint(authorization)}
    source_binding(record)
    directory.mkdir()
    temporary.mkdir(mode=0o700)
    command = ['systemd-run', '--user', '--no-block', '--expand-environment=no', '--unit=' + unit]
    for value in ['Type=oneshot', 'RemainAfterExit=yes', 'TimeoutStartSec=21630', 'TimeoutStopSec=60', 'KillMode=control-group',
                  'MemoryMax=256M', 'CPUQuota=25%', 'StandardOutput=append:' + str(directory / 'unit.log'),
                  'StandardError=append:' + str(directory / 'unit.log')]:
        command += ['-p', value]
    for value in ['LC_ALL=C', 'HOME=' + str(Path.home()), 'TMPDIR=' + str(temporary),
                  'PATH=' + str(Path.home() / '.local/bin') + ':/usr/local/bin:/usr/bin:/bin']:
        command += ['-E', value]
    command += [sys.executable, str(HERE / 'launch-runtime-storage-guard.py'), 'worker', '--directory', str(directory)]
    record.update(command=command, created_at=timestamp(), scope=__doc__)
    save(directory / 'invocation.json', record)
    result = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
    save(directory / 'launch-result.json', {'exit_status':result.returncode, 'stdout':result.stdout, 'stderr':result.stderr})
    require(result.returncode == 0, 'Storage guardian launch failed')


def seal(directory: Path) -> None:
    require(not (directory / 'proof-stopped.json').exists(), 'Preserve prior storage guardian seal')
    record = read(directory / 'invocation.json')
    source_binding(record)
    result = read(directory / 'worker-result.json')
    before = UNIT_API(record['unit'])
    require(before.get('Id') == record['unit'] and before.get('LoadState') == 'loaded' and TERMINAL(before) and int(before.get('ExecMainExitTimestampMonotonic') or '0') > 0, 'Storage guardian has not actually ended')
    require(before.get('MainPID') == '0' and before.get('ExecMainStatus') == str(result['exit_status']) and result['exit_status'] in {0, 1} and before.get('Result') == ('success' if result['exit_status'] == 0 else 'exit-code'), 'Storage guardian raw result differs')
    require(result['status'] == 'observed-producer-terminal' and TERMINAL(result['producer']), 'Producer terminal observation missing')
    require(result['exit_status'] == int(result['producer'].get('Result') != 'success' or result['producer'].get('ExecMainStatus') != '0'), 'Producer and guardian outcomes differ')
    for prune in result['prunes']:
        proof_path = Path(prune['proof_file'])
        require(proof_path in [Path(prune['directory']) / name for name in ['proof.json', 'skip-proof.json']], 'Storage cleanup proof path differs')
        require(fingerprint(proof_path) == prune['proof_sha256'], 'Storage cleanup proof changed')
    checked_output(['systemctl', '--user', 'stop', record['unit']])
    after = UNIT_API(record['unit'])
    stopped_states = {'inactive'} if result['exit_status'] == 0 else {'inactive', 'failed'}
    require(after.get('MainPID') == '0' and after.get('ActiveState') in stopped_states, 'Storage guardian did not stop')
    save(directory / 'proof-stopped.json', {'status':'completed-storage-observation-only', 'terminal':before, 'stopped':after,
         'producer_result':result['producer'], 'prunes':result['prunes'], 'build_or_image_accepted':False, 'scope':__doc__})
