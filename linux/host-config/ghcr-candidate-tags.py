#!/usr/bin/env python3
"""List old candidate-* tags for owner approval; deletes nothing. See docs/linux-host-setup.md § B8. ghcr registry hygiene."""

import argparse
import json
import subprocess
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
PREFIX = 'candidate-'


def select(versions: list[dict[str, Any]], now: datetime, min_age_days: int) -> list[dict[str, Any]]:
    """Versions whose every tag is a candidate tag and that are older than the cutoff."""
    cutoff = now - timedelta(days=min_age_days)
    chosen = []
    for version in versions:
        tags = version.get('metadata', {}).get('container', {}).get('tags') or []
        created = datetime.fromisoformat(version['created_at'])
        if tags and all(tag.startswith(PREFIX) for tag in tags) and created < cutoff:
            chosen.append({'id': version['id'], 'digest': version['name'], 'created_at': version['created_at'],
                           'tags': sorted(tags)})
    return sorted(chosen, key=lambda row: row['created_at'])


def named_in(row: dict[str, Any], root: Path) -> list[str]:
    """Tracked files that name the tag or the digest, so a reviewer sees which receipts lose their image."""
    needles = [*row['tags'], row['digest'].removeprefix('sha256:')[:12]]
    found: set[str] = set()
    for needle in needles:
        result = subprocess.run(['git', '-C', str(root), 'grep', '-l', '-F', needle], capture_output=True, text=True,
                                check=False, timeout=120)
        if result.returncode not in (0, 1):
            raise RuntimeError(f'git grep failed for {needle}: {result.stderr.strip()}')
        found.update(result.stdout.split())
    return sorted(found)


def load_versions(args: argparse.Namespace) -> list[dict[str, Any]]:
    if args.versions_file:
        return json.loads(Path(args.versions_file).read_text(encoding='utf-8'))
    raw = subprocess.run(['gh', 'api', '--paginate', '--slurp',
                          f'users/{args.owner}/packages/container/{args.package}/versions?per_page=100'],
                         capture_output=True, text=True, check=True, timeout=300).stdout
    return [version for page in json.loads(raw) for version in page]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--owner', default='Kataglyphis')
    parser.add_argument('--package', default='kataglyphis_beschleuniger')
    parser.add_argument('--min-age-days', type=int, default=30)
    parser.add_argument('--versions-file', help='a saved versions listing instead of the live API')
    parser.add_argument('--now', help='ISO timestamp for the cutoff; defaults to the current time')
    args = parser.parse_args()
    now = datetime.fromisoformat(args.now) if args.now else datetime.now(UTC)
    rows = select(load_versions(args), now, args.min_age_days)
    for row in rows:
        row['named_in'] = named_in(row, ROOT)
    tags = [tag for row in rows for tag in row['tags']]
    print(json.dumps({'package': args.package, 'min_age_days': args.min_age_days, 'cutoff': str(now - timedelta(
        days=args.min_age_days)), 'versions': rows, 'delete_command': (
        'bash linux/host-config/ghcr-delete-tags.sh ' + ' '.join(tags)) if tags else None}, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
