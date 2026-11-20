#!/usr/bin/env python3
"""Apply exact single-anchor source/doc edits through a preserved Git patch; refuse stale or escaping paths."""

import argparse
import difflib
import json
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', required=True, type=Path)
parser.add_argument('--edits', required=True, type=Path)
parser.add_argument('--patch', required=True, type=Path)
args = parser.parse_args()
root = args.source.resolve(strict=True)
assert subprocess.check_output(['git', '-C', str(root), 'rev-parse', '--show-toplevel'], text=True).strip() == str(root)
assert not args.patch.exists()
edits = json.loads(args.edits.read_text())
parts = []
for relative, replacements in edits.items():
    path = Path(relative)
    assert not path.is_absolute() and '..' not in path.parts
    target = (root / path).resolve(strict=True)
    assert target.is_relative_to(root) and target.is_file()
    before = target.read_text()
    after = before
    for change in replacements:
        assert change['before'] and after.count(change['before']) == 1, (relative, change['before'][:100])
        after = after.replace(change['before'], change['after'], 1)
    assert after != before, relative
    parts.extend(difflib.unified_diff(before.splitlines(keepends=True), after.splitlines(keepends=True), fromfile='a/' + relative, tofile='b/' + relative))
args.patch.write_text(''.join(parts))
subprocess.run(['git', '-C', str(root), 'apply', '--check', str(args.patch.resolve())], check=True)
subprocess.run(['git', '-C', str(root), 'apply', str(args.patch.resolve())], check=True)
print(f'Applied {len(edits)} anchored file changes; patch retained at {args.patch}')
