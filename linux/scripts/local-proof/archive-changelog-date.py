#!/usr/bin/env python3
"""Archive complete changelog dates with retained original bytes and rebased relative links."""

from __future__ import annotations

import argparse
import collections
import datetime
import hashlib
import json
import posixpath
import re
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', required=True, type=Path)
parser.add_argument('--through', required=True)
parser.add_argument('--receipt', required=True, type=Path)
args = parser.parse_args()
root = args.source.resolve(strict=True)
datetime.date.fromisoformat(args.through)
assert not args.receipt.exists()
path = root / 'CHANGELOG.md'
text = path.read_text()
headings = list(re.finditer(r'^## (\d{4}-\d\d-\d\d)\b', text, re.MULTILINE))
cut = next(match for match in headings if match[1] <= args.through)
assert cut[1] == args.through
assert all(match[1] > args.through for match in headings if match.start() < cut.start())
assert all(match[1] <= args.through for match in headings if match.start() >= cut.start())
prefix, moved = text[:cut.start()], text[cut.start():]
archive = root / 'docs' / ('changelog-archive-' + args.through + '.md')
assert not archive.exists()
dates = collections.Counter(re.findall(r'^## (\d{4}-\d\d-\d\d)\b', moved, re.MULTILINE))
first = min(dates)
label = args.through if first == args.through else first + ' … ' + args.through
previous = re.search(r'^> \[`([^`]+)`\]\(([^)]+)\)', prefix, re.MULTILINE)
assert previous
nav = f'> [`{label}`](docs/{archive.name}) ·\n'
prefix = prefix[:previous.start()] + nav + prefix[previous.start():]
links = re.compile(r'(\]\()(<[^>]+>|[^()\s]+)')
changes = []
def rebase(match: re.Match[str]) -> str:
    target = match[2]
    angle = target.startswith('<') and target.endswith('>')
    value = target[1:-1] if angle else target
    if value.startswith(('#', '/')) or re.match(r'^[A-Za-z][A-Za-z0-9+.-]*:', value):
        return match[0]
    filename, anchor_mark, anchor = value.partition('#')
    filename, query_mark, query = filename.partition('?')
    replacement = posixpath.relpath(filename, 'docs') + query_mark + query + anchor_mark + anchor
    if angle: replacement = '<' + replacement + '>'
    changes.append({'before': target, 'after': replacement})
    return match[1] + replacement
rebased = links.sub(rebase, moved)
assert links.sub(lambda match: match[1] + '@TARGET', moved) == links.sub(lambda match: match[1] + '@TARGET', rebased)
assert collections.Counter(re.findall(r'^## (\d{4}-\d\d-\d\d)\b', rebased, re.MULTILINE)) == dates
header = f'''<!--
Copyright (c) 2026 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Changelog archive — {label}

Entries moved from the root `CHANGELOG.md` on {datetime.datetime.now(datetime.UTC).date()} at a complete date
boundary. Original text is preserved; relative links are rebased to this directory.
The preceding history is in [the {previous[1]} archive]({Path(previous[2]).name}).

'''
original = args.receipt.with_name('changelog-moved-original.md')
assert not original.exists()
original.write_text(moved)
archive.write_text(header + rebased)
path.write_text(prefix.rstrip() + '\n')
record = {'status': 'archived-complete-dates-relative-links-only', 'archive': str(archive), 'through': args.through,
          'moved_entry_dates': dict(dates), 'moved_entries': sum(dates.values()), 'nonlink_bytes_preserved': True,
          'original_moved_text': str(original), 'original_sha256': hashlib.sha256(moved.encode()).hexdigest(),
          'rebased_sha256': hashlib.sha256(rebased.encode()).hexdigest(), 'rebased_links': changes,
          'remaining_root_lines': len(prefix.rstrip().splitlines()), 'source_entries_deleted': False}
args.receipt.write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps({key:record[key] for key in ['status','archive','moved_entries','remaining_root_lines','nonlink_bytes_preserved']}))
