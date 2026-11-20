"""Verify and share a stopped producer's BuildKit cache; no cache-hit, image or source-authentication proof."""

from __future__ import annotations

import json
import os
import shlex
from itertools import pairwise
from pathlib import Path
from typing import TYPE_CHECKING

from native_oci_layout import descriptor_path, sha
from native_oci_seed import plain_directory, plain_file
from proof_commands import checked_run

if TYPE_CHECKING:
    from proof_types import Json

MANIFEST = 'application/vnd.oci.image.manifest.v1+json'
CONFIG = 'application/vnd.buildkit.cacheconfig.v0'
METADATA = ('index.json', 'oci-layout')
STATUS = 'passed-verified-local-buildkit-cache-transfer-only'


def cache_layout(context: Path) -> tuple[dict[str, bytes], list[Json]]:
    context = plain_directory(context)
    for name in ('blobs', 'blobs/sha256'):
        plain_directory(context / name)
    for name in METADATA:
        plain_file(context / name)
    metadata = {name: (context / name).read_bytes() for name in METADATA}
    assert json.loads(metadata['oci-layout']) == {'imageLayoutVersion': '1.0.0'}, 'Unsupported cache layout'
    index = json.loads(metadata['index.json'])
    assert index['schemaVersion'] == 2 and len(index['manifests']) == 1, 'Cache must select exactly one manifest'
    selected = index['manifests'][0]
    assert selected['mediaType'] == MANIFEST, 'Unsupported cache manifest type'
    manifest = json.loads(descriptor_path(context, selected).read_bytes())
    assert manifest['schemaVersion'] == 2 and manifest['config']['mediaType'] == CONFIG, 'Not a BuildKit cache manifest'
    assert manifest['layers'], 'Cache contains no layers'
    records: dict[str, Json] = {}
    for row in [selected, manifest['config'], *manifest['layers']]:
        descriptor_path(context, row)
        assert row['digest'] not in records or records[row['digest']] == row, 'Conflicting cache descriptors'
        records[row['digest']] = row
    return metadata, list(records.values())


def stopped_producer(proof_path: Path) -> str:
    plain_file(proof_path)
    proof = json.loads(proof_path.read_bytes())
    terminal, stopped = proof['terminal'], proof['stopped']
    assert terminal['LoadState'] == 'loaded' and terminal['Result'] == 'success', 'Producer did not complete successfully'
    assert terminal['MainPID'] == '0' and terminal['ExecMainStatus'] == '0', 'Producer is live or failed'
    assert terminal['ActiveState'] == 'active' and terminal['SubState'] == 'exited', 'Producer has no successful terminal'
    assert stopped['ActiveState'] == 'inactive' and stopped['MainPID'] == '0', 'Producer proof is not stopped'
    unit = terminal['Id']
    assert unit == stopped['Id'] and unit.endswith('.service') and not unit.startswith('-'), 'Producer unit differs'
    command = ['systemctl', '--user', 'show', unit, '--property=ActiveState,MainPID']
    current = dict(line.split('=', 1) for line in checked_run(command).stdout.splitlines() if '=' in line)
    assert current == {'ActiveState': 'inactive', 'MainPID': '0'}, 'Cache producer is currently live'
    return unit


def disjoint_caches(source: Path, destination: Path) -> None:
    assert not destination.is_relative_to(source) and not source.is_relative_to(destination), 'Cache paths overlap'


def transfer_cache(source: Path, destination: Path, proof_path: Path, receipt: Path) -> Json:
    source = plain_directory(source)
    destination = plain_directory(destination.parent) / destination.name
    plain_directory(receipt.parent)
    assert not destination.exists() and not destination.is_symlink(), 'Preserve the existing destination'
    assert not receipt.exists() and not receipt.is_symlink(), 'Preserve the existing transfer receipt'
    disjoint_caches(source, destination)
    assert not receipt.absolute().is_relative_to(source) and not receipt.absolute().is_relative_to(destination), 'Receipt overlaps a cache'
    assert source.stat().st_dev == destination.parent.stat().st_dev, 'Cache sharing requires the same filesystem'
    unit = stopped_producer(proof_path)
    proof_hash = sha(proof_path)
    metadata, records = cache_layout(source)
    destination.mkdir(mode=0o700)
    (destination / 'blobs/sha256').mkdir(parents=True)
    for row in records:
        original = descriptor_path(source, row)
        target = destination / original.relative_to(source)
        os.link(original, target, follow_symlinks=False)
        descriptor_path(destination, row)
    for name, data in metadata.items():
        with (destination / name).open('xb') as stream:
            stream.write(data)
    assert all((source / name).read_bytes() == data for name, data in metadata.items()), 'Source metadata changed during transfer'
    assert sha(proof_path) == proof_hash and stopped_producer(proof_path) == unit, 'Producer proof changed'
    result = {'schema_version': 1, 'status': STATUS, 'source': str(source), 'destination': str(destination),
              'producer_proof': str(proof_path.absolute()), 'producer_proof_sha256': proof_hash, 'producer_unit': unit,
              'metadata_sha256': {name: sha(destination / name) for name in METADATA}, 'descriptors': records,
              'verified_unique_blobs': len(records), 'shared_unique_bytes': sum(row['size'] for row in records),
              'cache_hits_claimed': False, 'image_accepted': False, 'publication': False, 'scope': __doc__}
    with receipt.open('x') as stream:
        stream.write(json.dumps(result, indent=2) + '\n')
    return result


def verify_transfer(receipt: Path) -> Json:
    plain_file(receipt)
    record = json.loads(receipt.read_bytes())
    assert record['schema_version'] == 1 and record['status'] == STATUS, 'Unexpected cache transfer receipt'
    source, destination = (plain_directory(Path(record[name])) for name in ('source', 'destination'))
    disjoint_caches(source, destination)
    proof = Path(record['producer_proof'])
    assert sha(proof) == record['producer_proof_sha256'] and stopped_producer(proof) == record['producer_unit'], 'Producer proof differs'
    source_metadata, source_records = cache_layout(source)
    metadata, records = cache_layout(destination)
    assert metadata == source_metadata and records == source_records == record['descriptors'], 'Cache layout differs'
    assert record['metadata_sha256'] == {name: sha(destination / name) for name in METADATA}, 'Cache metadata differs'
    for name in METADATA:
        assert not (source / name).samefile(destination / name), 'Mutable cache metadata must be copied'
    for row in records:
        assert descriptor_path(source, row).samefile(descriptor_path(destination, row)), 'Cache blob is not shared'
    assert record['verified_unique_blobs'] == len(records), 'Cache blob count differs'
    assert record['shared_unique_bytes'] == sum(row['size'] for row in records), 'Cache byte accounting differs'
    assert record['cache_hits_claimed'] is record['image_accepted'] is record['publication'] is False, 'Cache transport grants no acceptance'
    return record


def verify_rendered_import(receipt: Path, log: Path, image: str) -> Json:
    record = verify_transfer(receipt)
    plain_file(log)
    commands = [shlex.split(line.removeprefix('[DRY RUN] ')) for line in log.read_text().splitlines() if line.startswith('[DRY RUN] ')]
    builds = [command for command in commands if len(command) > 1 and Path(command[0]).name == 'nerdctl' and command[1] == 'build']
    assert len(builds) == 1, 'Require exactly one rendered normal build'
    command = builds[0]
    pairs = list(pairwise(command))
    assert [value for flag, value in pairs if flag == '-t'] == [image], 'Rendered image differs'
    assert '--no-cache' not in command, 'Rendered build disables caching'
    imports = [value for flag, value in pairs if flag == '--cache-from' and value.startswith('type=local,')]
    assert imports == ['type=local,src=' + record['destination']], 'Rendered local cache import differs or is missing'
    return {**record, 'rendered_import_verified': True, 'dry_run_log_sha256': sha(log), 'rendered_image': image}
