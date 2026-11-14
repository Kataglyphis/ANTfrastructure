#!/usr/bin/env python3
"""Export reviewed ordinary ROCm amd64 GPU/Media/Android with native parent ancestry; no full licence closure, inference or FINAL acceptance."""

from __future__ import annotations

import argparse
import datetime
import json
import re
import runpy
import subprocess
import sys
from pathlib import Path
from typing import TYPE_CHECKING

from gpu_handoff_profile import STATUS, actual_image, load_gpu, terminal
from native_oci_layout import layer_ancestry, native_layout, sha
from native_oci_seed import ANDROID_STATUS, MEDIA_STATUS, verify_seed
from proof_commands import checked_run

if TYPE_CHECKING:
    from collections.abc import Callable

    from proof_types import Json

COMMON = runpy.run_path(str(Path(__file__).with_name('native-oci-handoff.py')))
EXPORTS = {'gpu': ('GPU', 'SDK', STATUS), 'media': ('Media', 'GPU', MEDIA_STATUS),
           'android': ('Android', 'Media', ANDROID_STATUS)}


def export_profile(kind: str) -> tuple[str, str, str]:
    assert kind in EXPORTS, 'Unreviewed native downstream export'
    return EXPORTS[kind]


def worker_inputs(kind: str = 'gpu') -> dict[str, str]:
    export_profile(kind)
    directory = Path(__file__).resolve().parent
    paths = [directory.parent / '01-core/context-management.sh',
             *(directory / name for name in ('native_oci_seed.py', 'native_oci_layout.py', 'native-oci-handoff.py', 'normal_stage_launch.py', 'stage_handoff_profile.py', 'gpu_handoff_profile.py', 'gpu-oci-handoff.py'))]
    if kind in {'media', 'android'}:
        paths += [directory / name for name in ('media_handoff_profile.py', 'media-oci-handoff.py')]
    if kind == 'android':
        paths += [directory / name for name in ('android_handoff_profile.py', 'android-oci-handoff.py')]
    return {str(path):sha(path) for path in paths}


def launch(args: argparse.Namespace, plan: Json, invocation: Json, actual: Json, kind: str = 'gpu') -> int:
    label = export_profile(kind)[0]
    invocation_path = Path(getattr(args, kind + '_invocation'))
    context = args.context
    path = context.with_suffix('.invocation.json')
    inputs = worker_inputs(kind)
    assert COMMON['state'](args.unit)['LoadState'] == 'not-found' and not context.exists() and not context.is_symlink(), 'Preserve existing export work'
    assert not path.exists(), 'Preserve existing export invocation'
    scripts = Path(__file__).resolve().parent.parent
    sys.path.insert(0, str(scripts))
    disk = runpy.run_path(str(scripts / 'launch-migraphx-configure-proof.py'))['require_build_disk'](context.parent)
    assert plan['required_bytes'] >= 193273528320 and disk['available_bytes'] >= plan['required_bytes'], 'Unchanged disk reserve required'
    helper = Path(next(iter(inputs)))
    reference = actual['manifest']
    command = COMMON['export_command'](helper, reference, context, invocation['parent_OCI_proof'], args.unit)
    record = {'created_at':datetime.datetime.now(datetime.UTC).isoformat(), 'unit':args.unit, 'context':str(context),
              label + '_invocation':str(invocation_path.resolve()), label + '_invocation_sha256':sha(invocation_path),
              'source_revision':invocation['source_revision'], 'parent_OCI_proof_sha256':invocation['parent_OCI_proof_sha256'],
              'actual_image':actual, 'command':command, 'disk_admission':disk, 'worker_inputs_sha256':inputs,
              'scope':__doc__, 'publication':False}
    COMMON['save'](path, record)
    result = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
    record.update(launch_status=result.returncode, stdout=result.stdout, stderr=result.stderr)
    COMMON['save'](path, record)
    print(json.dumps({'unit':args.unit, 'launch_status':result.returncode, 'manifest':actual['manifest']}))
    return result.returncode


def seal(args: argparse.Namespace, invocation: Json, parent: Json, actual: Json, kind: str = 'gpu') -> int:
    label, parent_label, receipt_status = export_profile(kind)
    invocation_path = Path(getattr(args, kind + '_invocation'))
    context = args.context
    path = context.with_suffix('.invocation.json')
    record = json.loads(path.read_text())
    assert record['unit'] == args.unit and record['context'] == str(context), f'{label} export binding differs'
    assert record[label + '_invocation'] == str(invocation_path.resolve()) and record['parent_OCI_proof_sha256'] == invocation['parent_OCI_proof_sha256'], f'{label} export input paths or parent proof differ'
    assert record[label + '_invocation_sha256'] == sha(invocation_path) and record['actual_image'] == actual, f'{label} export subject changed'
    assert record['worker_inputs_sha256'] == worker_inputs(kind) and record['launch_status'] == 0, f'{label} export inputs changed or launch failed'
    ended = terminal(args.unit)
    child = native_layout(context)
    assert child[0] == actual['manifest'] and child[1]['config']['digest'] == actual['config'], f'{label} native bytes differ'
    previous, reuse = verify_seed(Path(invocation['parent_OCI_proof']), context)
    transport = json.loads(Path(str(context) + '.transport.json').read_text())
    assert transport == {'producer_status':0, 'extractor_status':0}, f'{label} export producer or extractor failed'
    matched = layer_ancestry(child, previous, parent['layers'])
    proof: Json = {**record, 'status':receipt_status, 'terminal_before_stop':ended, 'manifest':child[0], 'config':child[1]['config']['digest'],
                   'index_sha256':sha(context / 'index.json'), 'layers':len(child[1]['layers']),
                   'all_native_blob_sizes_and_sha256_verified':True, 'matched_' + parent_label + '_layers_and_diffIDs':matched,
                   'parent_layer_reuse_verified':True, 'parent_layer_reuse':reuse, 'export_transport':transport,
                   'GPU_or_FINAL_acceptance':False, 'complete_binary_licence_review':False}
    assert not context.with_suffix('.proof.json').exists() and not context.with_suffix('.proof-stopped.json').exists(), f'Preserve sealed {label} proofs'
    COMMON['save'](context.with_suffix('.proof.json'), proof)
    checked_run(['systemctl', '--user', 'stop', args.unit])
    proof['stopped'] = COMMON['state'](args.unit)
    assert proof['stopped']['ActiveState'] == 'inactive' and proof['stopped']['MainPID'] == '0', f'{label} export did not stop'
    COMMON['save'](context.with_suffix('.proof-stopped.json'), proof)
    print(json.dumps({'status':receipt_status, 'matched_' + parent_label + '_layers_and_diffIDs':matched, 'manifest':child[0]}))
    return 0


def main_for(kind: str, loader: Callable[[Path, Path], tuple[Json, Json, Json]]) -> int:
    label = export_profile(kind)[0]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['launch', 'seal'])
    for name in ('compiler-plan', kind + '-invocation', 'context'):
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--unit', required=True)
    args = parser.parse_args()
    args.context = args.context.absolute()
    context = args.context
    assert context.parent.resolve(strict=True) == context.parent and context.name.startswith(kind + '-context-'), f'Fresh plain {label} context required'
    assert re.fullmatch(r'webgpu-normal-' + kind + r'-export-amd64-[0-9-]+\.service', args.unit), f'Unexpected {label} export unit'
    plan, invocation, parent = loader(args.compiler_plan, Path(getattr(args, kind + '_invocation')))
    actual = actual_image(invocation)
    return launch(args, plan, invocation, actual, kind) if args.action == 'launch' else seal(args, invocation, parent, actual, kind)


def main() -> int:
    return main_for('gpu', load_gpu)


if __name__ == '__main__':
    raise SystemExit(main())
