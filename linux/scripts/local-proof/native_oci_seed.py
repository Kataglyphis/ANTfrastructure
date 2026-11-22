#!/usr/bin/env python3
"""Share verified immutable parent layer bytes in a fresh OCI context; no source authentication, ABI or GPU acceptance."""

from __future__ import annotations

import argparse
import json
import os
import stat
from pathlib import Path
from typing import TYPE_CHECKING

from native_oci_layout import descriptor_path, native_layout, sha

if TYPE_CHECKING:
    from proof_types import Json, NativeLayout

MEDIA_STATUS = 'passed-native-ROCm-Media-OCI-and-GPU-ancestry-only'
ANDROID_STATUS = 'passed-native-ROCm-Android-OCI-and-Media-ancestry-only'
DEFAULT_MEDIA_STATUS = 'passed-native-default-amd64-Media-OCI-and-SDK-ancestry-only'
DEFAULT_ANDROID_STATUS = 'passed-native-default-amd64-Android-OCI-and-Media-ancestry-only'
NVIDIA_GPU_STATUSES = {arch: f'passed-native-NVIDIA-{arch}-GPU-OCI-and-SDK-ancestry-only' for arch in ('amd64', 'arm64')}
NVIDIA_MEDIA_STATUSES = {arch: f'passed-native-NVIDIA-{arch}-Media-OCI-and-GPU-ancestry-only' for arch in NVIDIA_GPU_STATUSES}
NVIDIA_STAGE_STATUSES = {*NVIDIA_GPU_STATUSES.values(), *NVIDIA_MEDIA_STATUSES.values()}

STAT_FIELDS = ('st_dev', 'st_ino', 'st_size', 'st_mode', 'st_uid', 'st_gid', 'st_mtime_ns', 'st_ctime_ns')


FOREIGN_DEFAULT_STATUSES = {
    status.replace('-amd64-', f'-{arch}-')
    for status in (DEFAULT_MEDIA_STATUS, DEFAULT_ANDROID_STATUS)
    for arch in ('arm64', 'riscv64')
}


def default_status(stage: str, arch: str) -> str:
    native = {'media': DEFAULT_MEDIA_STATUS, 'android': DEFAULT_ANDROID_STATUS}[stage]
    status = native.replace('-amd64-', f'-{arch}-')
    assert status == native or status in FOREIGN_DEFAULT_STATUSES, 'Unreviewed default OCI target'
    return status


def plain_directory(path: Path) -> Path:
    value = path.absolute()
    assert value.is_dir() and value.resolve(strict=True) == value, 'OCI context directory must have no symlink components'
    return value


def plain_file(path: Path) -> None:
    assert path.is_file() and not path.is_symlink(), 'OCI proof and metadata must be regular files'


def parent_layout(proof_path: Path) -> tuple[Json, Path, NativeLayout]:
    plain_file(proof_path)
    proof = json.loads(proof_path.read_text())
    assert proof['status'] in {'passed-qualified-native-compiler-OCI-and-base-ancestry', 'passed-qualified-native-SDK-OCI-and-compiler-ancestry', 'passed-native-ROCm-GPU-OCI-and-SDK-ancestry-only', MEDIA_STATUS, ANDROID_STATUS, DEFAULT_MEDIA_STATUS, DEFAULT_ANDROID_STATUS} or proof['status'] in FOREIGN_DEFAULT_STATUSES or proof['status'] in NVIDIA_STAGE_STATUSES, 'Verified native OCI parent required'
    assert proof['all_native_blob_sizes_and_sha256_verified'] is True, 'Parent blob verification is required'
    assert proof['stopped']['ActiveState'] == 'inactive' and proof['stopped']['MainPID'] == '0', 'Parent export must be sealed'
    context = plain_directory(Path(proof['context']))
    for name in ['blobs', 'blobs/sha256']:
        plain_directory(context / name)
    for name in ['index.json', 'oci-layout']:
        plain_file(context / name)
    layout = native_layout(context)
    assert sha(context / 'index.json') == proof['index_sha256'], 'Parent index bytes differ'
    assert layout[0] == proof['manifest'] and layout[1]['config']['digest'] == proof['config'], 'Parent manifest or config differs'
    assert len(layout[1]['layers']) == proof['layers'], 'Parent layer count differs'
    return proof, context, layout


def identity(path: Path, *, stable: bool = False) -> Json:
    value = path.lstat()
    assert stat.S_ISREG(value.st_mode), 'Only regular layer files may be shared'
    return {name: getattr(value, name) for name in STAT_FIELDS if not stable or name != 'st_ctime_ns'}


def unique_layers(layout: NativeLayout) -> list[Json]:
    return list({row['digest']: row for row in layout[1]['layers']}.values())


def receipt_path(context: Path) -> Path:
    return context.with_name(context.name + '.parent-links.json')


def seed_layers(proof_path: Path, context: Path) -> Json:
    proof, parent, layout = parent_layout(proof_path)
    context = plain_directory(context)
    assert not any(context.iterdir()), 'Shared OCI destination must be empty'
    assert not context.is_relative_to(parent) and not parent.is_relative_to(context), 'OCI parent and child contexts overlap'
    receipt = receipt_path(context)
    assert not receipt.exists() and not receipt.is_symlink(), 'Preserve the existing OCI seed receipt'
    (context / 'blobs/sha256').mkdir(parents=True)
    records: list[Json] = []
    for layer in unique_layers(layout):
        source = descriptor_path(parent, layer)
        destination = context / source.relative_to(parent)
        os.link(source, destination, follow_symlinks=False)
        descriptor_path(context, layer)
        records.append({'digest':layer['digest'], 'relative_path':str(destination.relative_to(context)), 'identity':identity(destination,stable=True)})
    result = {'schema_version':2, 'status':'seeded-verified-parent-layer-links-only', 'parent_proof':str(proof_path.resolve()),
              'parent_proof_sha256':sha(proof_path), 'parent_context':str(parent), 'child_context':str(context),
              'parent_manifest':layout[0], 'parent_index_sha256':proof['index_sha256'], 'linked_layers':records,
              'shared_unique_layer_bytes':sum(row['identity']['st_size'] for row in records), 'scope':__doc__}
    with receipt.open('x') as stream:
        stream.write(json.dumps(result,indent=2) + '\n')
    return result


def verify_seed(proof_path: Path, context: Path) -> tuple[NativeLayout, Json]:
    proof, parent, layout = parent_layout(proof_path)
    context = plain_directory(context)
    for name in ['blobs', 'blobs/sha256']:
        plain_directory(context / name)
    receipt = receipt_path(context)
    plain_file(receipt)
    record = json.loads(receipt.read_text())
    assert type(record['schema_version']) is int and record['schema_version'] in {1,2} and record['status'] == 'seeded-verified-parent-layer-links-only', 'Unexpected OCI seed receipt'
    stable = record['schema_version'] == 2
    assert record['parent_proof'] == str(proof_path.resolve()) and record['parent_proof_sha256'] == sha(proof_path), 'OCI seed parent proof differs'
    assert record['parent_context'] == str(parent) and record['child_context'] == str(context), 'OCI seed context binding differs'
    assert record['parent_manifest'] == layout[0] and record['parent_index_sha256'] == proof['index_sha256'], 'OCI seed parent identity differs'
    layers = unique_layers(layout)
    assert [row['digest'] for row in record['linked_layers']] == [row['digest'] for row in layers], 'OCI seed layer inventory differs'
    for row, layer in zip(record['linked_layers'],layers,strict=True):
        source = parent / 'blobs/sha256' / layer['digest'].split(':',1)[1]
        destination = context / source.relative_to(parent)
        assert row['relative_path'] == str(destination.relative_to(context)), 'OCI seed layer path differs'
        assert identity(source,stable=stable) == row['identity'] and identity(destination,stable=stable) == row['identity'], 'Shared OCI layer identity or parent metadata changed'
    assert record['shared_unique_layer_bytes'] == sum(layer['size'] for layer in layers), 'OCI shared-byte accounting differs'
    for name in ['index.json', 'oci-layout']:
        plain_file(context / name)
        assert (context / name).stat().st_ino != (parent / name).stat().st_ino or (context / name).stat().st_dev != (parent / name).stat().st_dev, 'OCI child metadata must remain independent'
    return layout, record


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--parent-proof', type=Path, required=True)
    parser.add_argument('--context', type=Path, required=True)
    args = parser.parse_args()
    result = seed_layers(args.parent_proof,args.context)
    print(json.dumps({'status':result['status'], 'linked_unique_layers':len(result['linked_layers']), 'shared_unique_layer_bytes':result['shared_unique_layer_bytes']}))


if __name__ == '__main__':
    main()
