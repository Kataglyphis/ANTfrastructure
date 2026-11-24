#!/usr/bin/env python3
"""The hub workflows' artifact retention policy; GitHub's expiry and consumer-owned workflows stay outside."""

import importlib
import sys
import unittest
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'linux/scripts'))
V = importlib.import_module('verify_workflow_conventions')
BY_REF = ("${{ inputs.artifact-retention-days || (github.ref == 'refs/heads/main' && 30) "
          "|| (github.ref == 'refs/heads/develop' && 14) || 5 }}")
REUSABLE = ('python-ci-linux.yml', 'python-ci-windows.yml', 'container-ci-windows.yml')
HANDOFFS = {'python-windows-arm64-stage', '${{ inputs.artifact-name }}-tests', 'sccache-${{ matrix.target }}'}
FIXED = {'python-docs-site': '7', **dict.fromkeys(HANDOFFS, '1')}


def uploads(name: str) -> list[Any]:
    steps: list[Any] = []
    V._steps(V.load_yaml(ROOT / '.github/workflows' / name), steps)
    return [V.value(step, 'with') for step in steps if 'actions/upload-artifact@' in str(V.value(step, 'uses') or '')]


def retention(block: Any) -> str:
    return str(V.value(block, 'retention-days'))


class RetentionTests(unittest.TestCase):
    def test_reusable_lanes_take_an_override_that_defaults_to_the_ref_policy(self) -> None:
        for name in REUSABLE:
            with self.subTest(workflow=name):
                inputs = V.value(V.value(V.value(V.load_yaml(ROOT / '.github/workflows' / name), 'on'), 'workflow_call'),
                                 'inputs')
                spec = V.value(inputs, 'artifact-retention-days')
                self.assertEqual((V.value(spec, 'type'), str(V.value(spec, 'default'))), ('number', '0'))

    def test_every_reusable_upload_keeps_the_ref_policy_or_is_a_same_run_handoff(self) -> None:
        for name in REUSABLE:
            blocks = uploads(name)
            self.assertGreater(len(blocks), 1, name)
            for block in blocks:
                artifact = str(V.value(block, 'name'))
                with self.subTest(workflow=name, artifact=artifact[:60]):
                    self.assertEqual(retention(block), FIXED.get(artifact, BY_REF))

    def test_the_arm64_bundle_lives_long_enough_only_for_a_manual_candidate(self) -> None:
        bundle = [b for b in uploads('windows-arm64.yml') if V.value(b, 'name') == 'winarm64-bundle']
        self.assertEqual([retention(b) for b in bundle], ["${{ github.event_name == 'workflow_dispatch' && 14 || 2 }}"])
        sccache = [b for b in uploads('sccache-release.yml') if str(V.value(b, 'name')) in HANDOFFS]
        self.assertEqual([retention(b) for b in sccache], ['1'])


if __name__ == '__main__':
    unittest.main()
