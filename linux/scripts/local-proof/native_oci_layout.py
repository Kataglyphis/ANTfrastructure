"""Hash native OCI descriptors and ancestry; these checks do not authenticate source receipts or prove GPU execution."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from proof_types import Json, NativeLayout


def sha(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def descriptor_path(context: Path, descriptor: Json) -> Path:
    algorithm, value = descriptor['digest'].split(':', 1)
    assert algorithm == 'sha256' and re.fullmatch(r'[0-9a-f]{64}', value), 'Invalid blob digest'
    path = context / 'blobs' / algorithm / value
    assert path.is_file() and not path.is_symlink(), 'Missing regular blob'
    assert path.stat().st_size == descriptor['size'] and sha(path) == value, 'Blob bytes differ from descriptor'
    return path


def native_layout(context: Path) -> NativeLayout:
    assert json.loads((context / 'oci-layout').read_text())['imageLayoutVersion'] == '1.0.0'
    index = json.loads((context / 'index.json').read_text())
    assert index['schemaVersion'] == 2 and len(index['manifests']) == 1, 'Native OCI must select exactly one manifest'
    selected = index['manifests'][0]
    manifest = json.loads(descriptor_path(context, selected).read_text())
    assert manifest['schemaVersion'] == 2
    config = json.loads(descriptor_path(context, manifest['config']).read_text())
    assert config['os'] == 'linux' and config['architecture'] == 'amd64', 'Compiler must be native Linux amd64'
    assert config['rootfs']['type'] == 'layers' and len(config['rootfs']['diff_ids']) == len(manifest['layers'])
    for layer in manifest['layers']:
        descriptor_path(context, layer)
    return selected['digest'], manifest, config


def layer_ancestry(child: NativeLayout, parent: NativeLayout, expected_count: int) -> int:
    _, manifest, config = child
    _, parent_manifest, parent_config = parent
    count = len(parent_manifest['layers'])
    assert count == expected_count and count >= 12 and len(manifest['layers']) >= count
    assert manifest['layers'][:count] == parent_manifest['layers'], 'Base layer ancestry differs'
    assert config['rootfs']['diff_ids'][:count] == parent_config['rootfs']['diff_ids'], 'Base diffID ancestry differs'
    return count


def base_ancestry(child: NativeLayout, parent: NativeLayout) -> int:
    return layer_ancestry(child, parent, 12)
