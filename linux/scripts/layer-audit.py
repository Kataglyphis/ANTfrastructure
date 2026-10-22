#!/usr/bin/env python3
# Dead bytes stay invisible to `docker history`; this counts them per layer (usage: --help).
import argparse
import collections
import json
import os
import tarfile


def layers_of(manifest_path):
    doc = json.load(open(manifest_path))
    doc = doc[0] if isinstance(doc, list) else doc
    return doc['Manifest']['layers']


def members(blob):
    with tarfile.open(blob, 'r:*') as tar:
        for m in tar:
            name = m.name[2:] if m.name.startswith('./') else m.name
            name = name.strip('/')
            if name:
                yield name, m.isreg(), m.size


def audit(layers, blob_dir, find=''):
    live = {}                                   # path -> (size, layer index), as the image sees it
    dead = collections.Counter()                # 'deleted' | 'replaced' -> bytes stored but no longer visible
    per_layer, found = [], []
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
                    whiteouts.append(('path', os.path.join(os.path.dirname(name), base[4:])))
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
        per_layer.append({'layer': i, 'compressed': layer['size'], 'unpacked': unpacked,
                          'files': len(files), 'whiteouts': len(whiteouts)})
    return {'layers': per_layer, 'live_bytes': sum(s for s, _ in live.values()),
            'deleted_bytes': dead['deleted'], 'replaced_bytes': dead['replaced'], 'found': found}


def main():
    ap = argparse.ArgumentParser(description='What an image stores, layer by layer')
    ap.add_argument('manifest')
    ap.add_argument('blob_dir')
    ap.add_argument('--json', action='store_true')
    ap.add_argument('--find', default='', help='report the layers holding this path prefix')
    args = ap.parse_args()
    report = audit(layers_of(args.manifest), args.blob_dir, args.find)
    if args.json:
        print(json.dumps(report))
        return
    for row in report['layers']:
        print(f"layer {row['layer']:02d} compressed={row['compressed']/1e9:6.2f}GB unpacked={row['unpacked']/1e9:6.2f}GB "
              f"files={row['files']} whiteouts={row['whiteouts']}")
    print(f"live {report['live_bytes']/1e9:.2f} GB; kept but dead: deleted {report['deleted_bytes']/1e6:.1f} MB, "
          f"replaced {report['replaced_bytes']/1e6:.1f} MB")
    for hit in report['found']:
        print(f"  {args.find} in layer {hit['layer']:02d}: {hit['path']} ({hit['size']/1e6:.1f} MB)")


if __name__ == '__main__':
    main()
