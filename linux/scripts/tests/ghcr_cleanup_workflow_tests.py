#!/usr/bin/env python3
"""The weekly GHCR prune's packages and guards; the registry and the PAT stay outside this suite."""

import importlib
import sys
import unittest
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'linux/scripts'))
V = importlib.import_module('verify_workflow_conventions')


def prune_steps() -> list[Any]:
    steps: list[Any] = []
    V._steps(V.load_yaml(ROOT / '.github/workflows/ghcr-cleanup.yml'), steps)
    return [V.value(step, 'env') for step in steps if 'ghcr-prune-package.sh' in str(V.value(step, 'run') or '')]


class PruneTests(unittest.TestCase):
    def test_both_packages_are_pruned_with_confirm_age_and_tag_guards(self) -> None:
        envs = prune_steps()
        packages = [V.value(env, 'GHCR_PKG') for env in envs]
        self.assertEqual(packages, [None, 'kataglyphis_beschleuniger-stages'])
        for env in envs:
            with self.subTest(package=V.value(env, 'GHCR_PKG')):
                self.assertEqual((V.value(env, 'GHCR_PRUNE_CONFIRM'), V.value(env, 'KEEP_DAYS')), ('1', '14'))
                self.assertEqual(V.value(env, 'GHCR_TOKEN'), '${{ secrets.GHCR_TOKEN }}')

    def test_only_the_stage_package_lowers_the_empty_inventory_guard(self) -> None:
        public, stages = prune_steps()
        self.assertIsNone(V.value(public, 'MIN_TAGS'))
        self.assertEqual(V.value(stages, 'MIN_TAGS'), '3')


if __name__ == '__main__':
    unittest.main()
