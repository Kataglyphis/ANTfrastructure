#!/usr/bin/env python3
"""Refusals of the ARM64 acceptance tool without a registry, GitHub or device; real runs stay required."""

import os
import runpy
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[3]
TOOL = runpy.run_path(str(ROOT / 'linux/scripts/local-proof/windows-arm64-acceptance.py'))
DIGEST_A = 'sha256:' + 'a' * 64
DIGEST_B = 'sha256:' + 'b' * 64
GOOD_LOG = ('[bk] TARGET ARCH: arm64 (CROSS build)\n#6 100.3   Failed:  0\n'
            '[bk:publish-gate] OK -> (warm solve, no output)\n[bk] Done in 01:25:24.')


def receipt(**export: Any) -> dict[str, Any]:
    image = f'{TOOL["IMAGE"]}@{DIGEST_A}'
    values = {'SchemaVersion': 1, 'HubCommit': 'c' * 40, 'RunId': '7', 'RunAttempt': '1', 'Image': image,
              'RequestedImage': image, 'ImageConfig': DIGEST_B, 'BundleSha256': 'd' * 64}
    values.update(export)
    return {'Export': values, 'DeviceArchitecture': 'ARM64', 'GateExitCode': 0, 'Passed': True}


class ClosureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix='ant-arm64-acceptance-')
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', LC_ALL='C')
        self.git('init', '-q', '-b', 'develop')
        self.base = self.commit('notes/a.md')

    def git(self, *args: str) -> str:
        result = subprocess.run(['git', '-C', str(self.repo), '-c', 'user.name=t', '-c', 'user.email=t@example.invalid',
                                 *args], env=self.env, capture_output=True, text=True, check=True, timeout=60)
        return result.stdout.strip()

    def commit(self, path: str) -> str:
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(target.read_text() + 'x' if target.exists() else 'x', encoding='utf-8')
        self.git('add', '-A')
        self.git('commit', '-q', '-m', path)
        return self.git('rev-parse', 'HEAD')

    def test_a_later_docs_or_linux_only_commit_reuses_the_image(self) -> None:
        self.commit('notes/b.md')
        later = self.commit('linux/scripts/local-proof/x.py')
        self.assertEqual(TOOL['closure_changes'](self.base, later, self.repo), [])
        TOOL['require_reuse'](self.base, later, self.repo)

    def test_each_windows_closure_path_blocks_reuse(self) -> None:
        for path in ['windows/scripts/build/X.ps1', 'linux/scripts/01-core/versions.env',
                     'linux/scripts/03-media/free-threaded-twins.txt', 'shared/upstream/migraphx/p.patch',
                     'linux/scripts/02-toolchain/python/free-threaded-wheel.py']:
            with self.subTest(path=path):
                later = self.commit(path)
                self.assertIn(path, TOOL['closure_changes'](self.base, later, self.repo))
                with self.assertRaisesRegex(ValueError, 'Windows build closure'):
                    TOOL['require_reuse'](self.base, later, self.repo)

    def test_a_commit_that_does_not_descend_from_the_image_source_is_refused(self) -> None:
        later = self.commit('notes/c.md')
        with self.assertRaisesRegex(ValueError, 'does not descend'):
            TOOL['closure_changes'](later, self.base, self.repo)
        with self.assertRaisesRegex(ValueError, 'full commit'):
            TOOL['closure_changes'](self.base[:8], later, self.repo)


class EvidenceTests(unittest.TestCase):
    def test_the_final_log_names_exactly_one_manifest_and_config(self) -> None:
        line = f'#12 exporting manifest {DIGEST_A} done\n#12 exporting config {DIGEST_B} done\n'
        self.assertEqual(TOOL['graded_identity'](line), (DIGEST_A, DIGEST_B))
        for log in ['', line + line, f'#12 exporting manifest {DIGEST_A} done\n']:
            with self.subTest(log=log[:20]), self.assertRaisesRegex(ValueError, 'exactly one'):
                TOOL['graded_identity'](log)

    def test_the_driver_log_must_prove_an_arm64_smoke_and_publish_gate(self) -> None:
        TOOL['require_graded'](GOOD_LOG)
        broken = {'amd64': GOOD_LOG.replace('arm64', 'amd64'), 'skipped': GOOD_LOG + '\n[bk:smoke-gate] SKIPPED',
                  'failed': GOOD_LOG.replace('Failed:  0', 'Failed:  1'),
                  'no-publish': GOOD_LOG.replace('[bk:publish-gate] OK', ''),
                  'incomplete': GOOD_LOG.replace('[bk] Done in', '')}
        for name, log in broken.items():
            with self.subTest(case=name), self.assertRaises(ValueError):
                TOOL['require_graded'](log)

    def test_the_device_log_needs_every_step_at_the_original_floor(self) -> None:
        TOOL['device_verdict']('22 passed, 0 failed (floor 22)', 22)
        for log in ['21 passed, 1 failed (floor 22)', '20 passed, 0 failed (floor 20)', '',
                    '22 passed, 0 failed (floor 22)\n22 passed, 0 failed (floor 22)']:
            with self.subTest(log=log), self.assertRaisesRegex(ValueError, 'all 22 steps'):
                TOOL['device_verdict'](log, 22)

    def test_a_receipt_binds_source_run_attempt_status_and_immutable_image(self) -> None:
        self.assertEqual(TOOL['check_receipt'](receipt(), 'c' * 40, 7, 1)['ImageConfig'], DIGEST_B)
        masked = receipt()
        masked['GateExitCode'] = 1
        arm = receipt()
        arm['DeviceArchitecture'] = 'AMD64'
        cases = {'source': (receipt(), 'e' * 40, 7, 1), 'run': (receipt(), 'c' * 40, 8, 1),
                 'attempt': (receipt(), 'c' * 40, 7, 2), 'masked': (masked, 'c' * 40, 7, 1),
                 'architecture': (arm, 'c' * 40, 7, 1),
                 'mutable': (receipt(Image=f'{TOOL["IMAGE"]}:winarm64'), 'c' * 40, 7, 1),
                 'foreign': (receipt(Image=f'ghcr.io/other/image@{DIGEST_A}'), 'c' * 40, 7, 1),
                 'config': (receipt(ImageConfig='latest'), 'c' * 40, 7, 1)}
        for name, (value, source, run, attempt) in cases.items():
            with self.subTest(case=name), self.assertRaises(ValueError):
                TOOL['check_receipt'](value, source, run, attempt)

    def test_promotion_keeps_the_tag_platform_and_the_graded_revision(self) -> None:
        before = {'Os': 'windows', 'Architecture': 'amd64', 'Variant': None, 'OsVersion': '10.0.26100.1'}
        TOOL['require_platform'](dict(before), before)
        for change in [{'Architecture': 'arm64'}, {'OsVersion': '10.0.26100.2'}, {'Os': 'linux'}]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                TOOL['require_platform'](dict(before, **change), before)
        TOOL['require_revision']('946c1637', '946c1637' + 'e' * 32)
        for revision in ['871804d4', 'main', '']:
            with self.subTest(revision=revision), self.assertRaisesRegex(ValueError, 'graded image source'):
                TOOL['require_revision'](revision, '946c1637' + 'e' * 32)

    def test_only_the_arm64_tag_or_an_exact_digest_is_read(self) -> None:
        self.assertEqual(TOOL['check_reference']('winarm64'), 'winarm64')
        self.assertEqual(TOOL['check_reference'](DIGEST_A), DIGEST_A)
        for reference in ['winamd64', 'latest', 'sha256:abc']:
            with self.subTest(reference=reference), self.assertRaises(ValueError):
                TOOL['check_reference'](reference)


if __name__ == '__main__':
    unittest.main()
