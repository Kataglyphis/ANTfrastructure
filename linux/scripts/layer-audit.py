#!/usr/bin/env python3
# Dead bytes stay invisible to `docker history`; this counts them per layer (usage: --help).
import argparse
import collections
import json
import os
import posixpath
import tarfile
from collections.abc import Iterator, Sequence
from typing import Any, TypedDict


class LayerDescriptor(TypedDict):
    digest: str
    size: int


class LayerSummary(TypedDict):
    layer: int
    step: str
    compressed: int
    unpacked: int
    files: int
    whiteouts: int


class FoundEntry(TypedDict):
    layer: int
    path: str
    size: int


class AuditReport(TypedDict):
    layers: list[LayerSummary]
    live_bytes: int
    deleted_bytes: int
    replaced_bytes: int
    found: list[FoundEntry]


STEP_LABEL = 'LABEL kataglyphis.step='


def _manifest(manifest_path: str) -> dict[str, Any]:
    with open(manifest_path, encoding='utf-8') as handle:
        doc = json.load(handle)
    doc = doc[0] if isinstance(doc, list) else doc
    return doc['Manifest']


def layers_of(manifest_path: str) -> list[LayerDescriptor]:
    return _manifest(manifest_path)['layers']


def config_path_of(manifest_path: str, blob_dir: str) -> str:
    digest = _manifest(manifest_path).get('config', {}).get('digest', '')
    path = os.path.join(blob_dir, digest.split(':', 1)[-1]) if digest else ''
    return path if path and os.path.isfile(path) else ''


def layer_steps(history: Sequence[dict[str, Any]]) -> list[str]:
    """One name per non-empty layer: the step label right before it, else what created it."""
    steps: list[str] = []
    pending = ''
    for entry in history:
        created = str(entry.get('created_by', ''))
        if entry.get('empty_layer'):
            # A step label names only the next RUN's layer; an ARG or ENV between them keeps it, an empty RUN spends it.
            if created.startswith(STEP_LABEL):
                pending = created[len(STEP_LABEL):].strip().strip('"')
            elif created.startswith('RUN '):
                pending = ''
            continue
        steps.append(pending or created.strip()[:60])
        pending = ''
    return steps


def steps_of(config_path: str) -> list[str]:
    if not config_path:
        return []
    with open(config_path, encoding='utf-8') as handle:
        return layer_steps(json.load(handle).get('history', []))


def members(blob: str) -> Iterator[tuple[str, bool, int]]:
    with tarfile.open(blob, 'r:*') as tar:
        for m in tar:
            name = m.name.removeprefix('./')
            name = name.strip('/')
            if name:
                yield name, m.isreg(), m.size


def audit(layers: Sequence[LayerDescriptor], blob_dir: str, find: str = '',
          steps: Sequence[str] = ()) -> AuditReport:
    live: dict[str, tuple[int, int]] = {}
    dead: collections.Counter[str] = collections.Counter()
    per_layer: list[LayerSummary] = []
    found: list[FoundEntry] = []
    names = [*steps[:len(layers)], *['?'] * (len(layers) - len(steps))]
    for i, layer in enumerate(layers):
        blob = os.path.join(blob_dir, layer['digest'].split(':', 1)[1])
        unpacked, whiteouts, files = 0, [], {}
        for name, is_reg, size in members(blob):
            unpacked += size
            base = os.path.basename(name)
            if base.startswith('.wh.'):
                if base == '.wh..wh..opq':
                    whiteouts.append(('dir', os.path.dirname(name)))
                else:
                    whiteouts.append(('path', posixpath.join(posixpath.dirname(name), base[4:])))
                continue
            if is_reg:
                files[name] = size
            if find and name.startswith(find):
                found.append({'layer': i, 'path': name, 'size': size})
        for kind, target in whiteouts:
            for p in list(live):
                under = p.startswith(target + '/')
                if under or (kind == 'path' and p == target):
                    dead['deleted'] += live.pop(p)[0]
        for p, size in files.items():
            if p in live:
                dead['replaced'] += live[p][0]
            live[p] = (size, i)
        per_layer.append({'layer': i, 'step': names[i], 'compressed': layer['size'], 'unpacked': unpacked,
                          'files': len(files), 'whiteouts': len(whiteouts)})
    return {'layers': per_layer, 'live_bytes': sum(s for s, _ in live.values()),
            'deleted_bytes': dead['deleted'], 'replaced_bytes': dead['replaced'], 'found': found}


def main() -> None:
    ap = argparse.ArgumentParser(description='What an image stores, layer by layer')
    ap.add_argument('manifest')
    ap.add_argument('blob_dir')
    ap.add_argument('--json', action='store_true')
    ap.add_argument('--find', default='', help='report the layers holding this path prefix')
    ap.add_argument('--config', default='', help="the image config JSON (default: the manifest's config blob)")
    args = ap.parse_args()
    steps = steps_of(args.config or config_path_of(args.manifest, args.blob_dir))
    report = audit(layers_of(args.manifest), args.blob_dir, args.find, steps)
    if args.json:
        print(json.dumps(report))
        return
    for row in report['layers']:
        print(f"layer {row['layer']:02d} compressed={row['compressed']/1e9:6.2f}GB unpacked={row['unpacked']/1e9:6.2f}GB "
              f"files={row['files']} whiteouts={row['whiteouts']} step={row['step']}")
    print(f"live {report['live_bytes']/1e9:.2f} GB; kept but dead: deleted {report['deleted_bytes']/1e6:.1f} MB, "
          f"replaced {report['replaced_bytes']/1e6:.1f} MB")
    for hit in report['found']:
        print(f"  {args.find} in layer {hit['layer']:02d}: {hit['path']} ({hit['size']/1e6:.1f} MB)")


if __name__ == '__main__':
    main()
