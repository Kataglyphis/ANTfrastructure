#!/usr/bin/env python3
"""Run the complete local FINAL contract in one owned bounded unit; no registry promotion, complete licence or GPU proof."""

from __future__ import annotations

import argparse
import os
import re
import runpy
import shlex
import subprocess
import sys
import uuid
from pathlib import Path
from types import SimpleNamespace
from typing import Any

from host_commands import checked_output
from owned_containers import OwnedContainers
from source_ci.common import fingerprint, read, require, save, timestamp

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ENGINE = str(Path.home() / '.local/bin/nerdctl')
OWNER = 'org.kataglyphis.local-final'
TIMEOUT = 21600
API = runpy.run_path(str(HERE / 'image-acceptance.py'))
UNIT_STATE = runpy.run_path(str(HERE / 'seal-mutation-unit.py'))['unit_state']
TERMINAL = runpy.run_path(str(HERE / 'watch-build-units.py'))['terminal']


def workers(variant: str = '') -> list[Path]:
    runtime = API['local_module']().local_api('runtime_launch_profile').runtime_worker_files(ROOT, nvidia=variant == 'nvidia')
    return sorted({*runtime, Path(__file__), HERE / 'image-acceptance.py', HERE / 'image_acceptance_local.py', HERE / 'runtime_terminal_evidence.py',
                   HERE / 'source_ci/common.py', HERE / 'seal-mutation-unit.py', HERE / 'watch-build-units.py',
                   ROOT / 'shared/config/image-consumers.json'})


def clean_source(revision: str) -> None:
    require(checked_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD']).strip() == revision, 'FINAL launcher revision changed')
    require(not checked_output(['git', '-C', str(ROOT), 'status', '--porcelain']).strip(), 'Commit FINAL tooling before use')


def binding(directory: Path, record: dict[str, Any]) -> None:
    require(record['source'] == str(ROOT) and record['engine'] == ENGINE, 'FINAL tooling or engine belongs elsewhere')
    require(record['owner_label'] == OWNER, 'FINAL ownership label differs')
    require(type(record['timeout_seconds']) is int and record['timeout_seconds'] == TIMEOUT, 'FINAL deadline profile differs')
    OwnedContainers(ENGINE, OWNER, record['run_id'])
    require(re.fullmatch(r'webgpu-local-final-' + record['platform'].removeprefix('linux/') + r'-[0-9-]+\.service', record['unit']), 'FINAL unit identity differs')
    clean_source(record['revision'])
    require(record['workers_sha256'] == {str(path):fingerprint(path) for path in workers(record['local_subject']['variant'])}, 'FINAL launcher worker closure changed')
    require(fingerprint(Path(record['runtime_invocation'])) == record['runtime_invocation_sha256'], 'FINAL runtime invocation changed')
    require(fingerprint(directory / 'plan.json') == record['plan_sha256'], 'FINAL plan bytes changed')
    plan = API['read_plan'](directory / 'plan.json')
    API['local_module']().complete_plan(plan, API['read_plan'](API['DEFAULT_PLAN']))
    require(plan['platform'] == record['platform'], 'FINAL plan platform differs')


def launch(runtime_path: Path, image: str, directory: Path, unit: str) -> None:
    require(not directory.exists() and not directory.is_symlink(), 'Preserve existing FINAL output')
    directory = directory.resolve()
    runtime_path = runtime_path.resolve(strict=True)
    runtime = read(runtime_path)
    platform = 'linux/' + runtime['target_arch']
    require(runtime['target_arch'] in {'amd64', 'arm64', 'riscv64'}, 'Unsupported FINAL architecture')
    require(re.fullmatch(r'webgpu-local-final-' + runtime['target_arch'] + r'-[0-9-]+\.service', unit), 'Explicit bounded FINAL unit required')
    require(UNIT_STATE(unit).get('LoadState') == 'not-found', 'Preserve an existing FINAL unit')
    revision = checked_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD']).strip()
    clean_source(revision)
    origin, _ = API['local_module']().observe(ENGINE, image, platform, runtime_path)
    temporary = Path.home() / '.cache' / unit.removesuffix('.service')
    require(not temporary.exists() and all(not (path / '.git').exists() for path in [temporary, *temporary.parents]), 'FINAL TMPDIR must be fresh and outside Git')
    owner = OwnedContainers(ENGINE, OWNER, uuid.uuid4().hex)
    require(not owner.ids(owned=True), 'FINAL invocation ownership already exists')
    directory.mkdir(parents=True)
    temporary.mkdir(mode=0o700)
    API['materialize_plan'](str(API['DEFAULT_PLAN']), str(directory / 'plan.json'), platform)
    cleanup = [sys.executable, str(HERE / 'cleanup-owned-containers.py'), '--engine', ENGINE, '--owner-label', OWNER,
               '--run-id', owner.run_id, '--cidfile', str(directory / 'container.cid'), '--output', str(directory / 'cleanup.json')]
    command = ['systemd-run', '--user', '--no-block', '--expand-environment=no', '--unit=' + unit]
    properties = ['Type=oneshot', 'RemainAfterExit=yes', 'TimeoutStartSec=' + str(TIMEOUT), 'TimeoutStopSec=300',
                  'KillMode=control-group', 'WorkingDirectory=' + str(ROOT), 'ExecStopPost=' + shlex.join(cleanup),
                  'StandardOutput=append:' + str(directory / 'unit.log'), 'StandardError=append:' + str(directory / 'unit.log')]
    for value in properties:
        command += ['-p', value]
    for value in ['LC_ALL=C', 'HOME=' + str(Path.home()), 'TMPDIR=' + str(temporary),
                  'PATH=' + str(Path.home() / '.local/bin') + ':/usr/local/bin:/usr/bin:/bin',
                  'ANT_RUNTIME_ENGINE=' + ENGINE, 'ANT_RUNTIME_OWNER_LABEL=' + OWNER, 'ANT_RUNTIME_RUN_ID=' + owner.run_id]:
        command += ['-E', value]
    command += [sys.executable, str(Path(__file__).resolve()), 'worker', '--directory', str(directory)]
    record = {'source':str(ROOT), 'revision':revision, 'workers_sha256':{str(path):fingerprint(path) for path in workers(origin['variant'])},
              'unit':unit, 'engine':ENGINE, 'owner_label':OWNER, 'run_id':owner.run_id, 'platform':platform, 'image':image,
              'runtime_invocation':str(runtime_path), 'runtime_invocation_sha256':fingerprint(runtime_path), 'local_subject':origin,
              'plan_sha256':fingerprint(directory / 'plan.json'), 'command':command, 'cleanup_command':cleanup,
              'created_at':timestamp(), 'timeout_seconds':TIMEOUT, 'scope':__doc__}
    save(directory / 'invocation.json', record)
    binding(directory, record)
    result = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
    save(directory / 'launch-result.json', {'exit_status':result.returncode, 'stdout':result.stdout, 'stderr':result.stderr})
    require(result.returncode == 0, 'FINAL bounded unit launch failed')


def worker(directory: Path) -> None:
    record = read(directory / 'invocation.json')
    binding(directory, record)
    state = UNIT_STATE(record['unit'])
    require(state.get('Id') == record['unit'] and state.get('LoadState') == 'loaded' and state.get('ActiveState') in {'active', 'activating'} and state.get('MainPID') == str(os.getpid()), 'FINAL worker is outside its bounded unit')
    expected = {'ANT_RUNTIME_ENGINE':ENGINE, 'ANT_RUNTIME_OWNER_LABEL':OWNER, 'ANT_RUNTIME_RUN_ID':record['run_id']}
    require(all(os.environ.get(key) == value for key, value in expected.items()), 'FINAL container ownership environment differs')
    origin, _ = API['local_module']().observe(ENGINE, record['image'], record['platform'], Path(record['runtime_invocation']))
    require(origin == record['local_subject'], 'FINAL producer changed before consumers')
    args = SimpleNamespace(image=record['image'], plan=str(directory / 'plan.json'), workspace=str(directory / 'consumers'),
                           receipt=str(directory / 'receipt.json'), engine=str(HERE / 'owned-nerdctl.py'), replay=None,
                           local_runtime_invocation=record['runtime_invocation'])
    API['check'](args)
    receipt = read(directory / 'receipt.json')
    API['validate_receipt'](receipt, record['image'], directory / 'plan.json', allow_local=True)
    require(receipt['hub_revision'] == record['revision'] and receipt['local_subject'] == record['local_subject'], 'FINAL consumer receipt changed source or producer')
    save(directory / 'worker-result.json', {'status':'completed-consumers-cleanup-pending', 'receipt_sha256':fingerprint(directory / 'receipt.json'),
         'exit_status':0, 'consumer_names':[row['name'] for row in receipt['consumers']], 'scope':__doc__})


def consumer_result(directory: Path, record: dict[str, Any]) -> None:
    result = read(directory / 'worker-result.json')
    require(result['status'] == 'completed-consumers-cleanup-pending' and type(result['exit_status']) is int and result['exit_status'] == 0 and result['receipt_sha256'] == fingerprint(directory / 'receipt.json'), 'FINAL worker result differs')
    receipt = API['validate_receipt'](read(directory / 'receipt.json'), record['image'], directory / 'plan.json', allow_local=True)
    require(receipt['hub_revision'] == record['revision'] and receipt['local_subject'] == record['local_subject'] and result['consumer_names'] == [row['name'] for row in receipt['consumers']], 'FINAL sealed source, producer or consumer order differs')
    API['local_module']().recheck(ENGINE, record['image'], record['platform'], record['runtime_invocation'], record['local_subject'])


def cleanup_evidence(directory: Path, record: dict[str, Any]) -> dict[str, str]:
    cleanup = read(directory / 'cleanup.json')
    require(type(cleanup.get('exit_status')) is int and cleanup['exit_status'] == 0 and cleanup.get('owner_label') == OWNER and cleanup.get('run_id') == record['run_id'], 'FINAL owned cleanup failed or differs')
    query = subprocess.run([ENGINE, 'ps', '-a', '--filter', 'label=' + OWNER + '=' + record['run_id'], '--format', '{{json .}}'],
                           capture_output=True, text=True, timeout=60, check=False)
    save(directory / 'independent-engine-query.json', {'returncode':query.returncode, 'stdout':query.stdout, 'stderr':query.stderr})
    require(query.returncode == 0 and not query.stdout.strip(), 'FINAL owned containers remain or query failed')
    return {'cleanup_sha256':fingerprint(directory / 'cleanup.json'),
            'independent_engine_query_sha256':fingerprint(directory / 'independent-engine-query.json')}


def seal(directory: Path) -> int:
    require(not (directory / 'proof-stopped.json').exists(), 'Preserve previous FINAL proof')
    record = read(directory / 'invocation.json')
    binding(directory, record)
    before = UNIT_STATE(record['unit'])
    require(before.get('Id') == record['unit'] and before.get('LoadState') == 'loaded' and TERMINAL(before) and int(before.get('ExecMainExitTimestampMonotonic') or '0') > 0 and before.get('MainPID') == '0', 'FINAL unit has not actually terminated')
    status = int(before['ExecMainStatus'])
    require((before.get('Result') == 'success') == (status == 0), 'FINAL unit raw outcome differs')
    receipt_path = directory / 'receipt.json'
    if status == 0:
        consumer_result(directory, record)
    checked_output(['systemctl', '--user', 'stop', record['unit']], timeout=180)
    after = UNIT_STATE(record['unit'])
    require(after.get('MainPID') == '0' and after.get('ActiveState') in {'inactive', 'failed'}, 'FINAL unit did not stop')
    require(status != 0 or (after.get('ActiveState') == 'inactive' and after.get('Result') == 'success'), 'FINAL successful unit failed during stop')
    evidence = cleanup_evidence(directory, record)
    save(directory / 'proof-stopped.json', {'status':'passed-bounded-local-final-consumers' if status == 0 else 'failed-bounded-local-final-preserved',
         'terminal':before, 'stopped':after, 'source_revision':record['revision'], 'raw_exit_status':status,
         'run_id':record['run_id'], 'invocation_sha256':fingerprint(directory / 'invocation.json'), 'plan_sha256':record['plan_sha256'],
         'receipt_sha256':fingerprint(receipt_path) if receipt_path.is_file() else None,
         **evidence,
         'owned_containers_absent':True, 'registry_promotion':False, 'GPU_inference_proved':False, 'scope':__doc__})
    return status


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['launch', 'worker', 'seal'])
    parser.add_argument('--directory', required=True, type=Path)
    parser.add_argument('--runtime-invocation', type=Path)
    parser.add_argument('--image')
    parser.add_argument('--unit')
    args = parser.parse_args()
    if args.action == 'launch':
        if args.runtime_invocation is None or args.image is None or args.unit is None:
            parser.error('launch requires runtime-invocation, image and unit')
        launch(args.runtime_invocation, args.image, args.directory, args.unit)
    elif args.action == 'worker':
        worker(args.directory)
    else:
        return seal(args.directory)
    return 0


if __name__ == '__main__':
    sys.exit(main())
