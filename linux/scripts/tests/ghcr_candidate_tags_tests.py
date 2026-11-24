#!/usr/bin/env python3
"""Candidate-tag selection over a fixed listing; the live API, git history and deletion stay outside."""

import runpy
import unittest
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[3]
TOOL = runpy.run_path(str(ROOT / 'linux/host-config/ghcr-candidate-tags.py'))
NOW = datetime(2026, 11, 24, tzinfo=UTC)


def version(number: int, created: str, *tags: str) -> dict[str, Any]:
    return {'id': number, 'name': f'sha256:{number:064x}', 'created_at': created,
            'metadata': {'container': {'tags': list(tags)}}}


class SelectTests(unittest.TestCase):
    def test_only_old_versions_carrying_nothing_but_candidate_tags_are_listed(self) -> None:
        listing = [version(1, '2026-10-01T00:00:00Z', 'candidate-1'),
                   version(2, '2026-10-01T00:00:00Z', 'candidate-2', 'latest'),
                   version(3, '2026-11-20T00:00:00Z', 'candidate-3'),
                   version(4, '2026-09-01T00:00:00Z'),
                   version(5, '2026-09-01T00:00:00Z', 'winarm64'),
                   version(6, '2026-09-15T00:00:00Z', 'candidate-6b', 'candidate-6a')]
        rows = TOOL['select'](listing, NOW, 30)
        self.assertEqual([row['id'] for row in rows], [6, 1])
        self.assertEqual(rows[0]['tags'], ['candidate-6a', 'candidate-6b'])

    def test_the_age_cutoff_is_strict(self) -> None:
        listing = [version(1, '2026-10-25T00:00:00Z', 'candidate-1'), version(2, '2026-10-24T23:59:59Z', 'candidate-2')]
        self.assertEqual([row['id'] for row in TOOL['select'](listing, NOW, 30)], [2])


if __name__ == '__main__':
    unittest.main()
