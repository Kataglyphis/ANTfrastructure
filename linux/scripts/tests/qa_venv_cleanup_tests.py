"""Exercise disposable trees and fake host observations, not actual host idleness, authorization authenticity or locking."""

from __future__ import annotations

import importlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, cast
from unittest import mock

OWNER = Path(sys.argv.pop(1)).resolve()
FIXTURE = Path(sys.argv.pop(1)).resolve()
sys.path[:0] = [str(OWNER), str(OWNER.parent / 'scripts')]
MODULE = importlib.import_module('qa_venv_cleanup')
USAGE = importlib.import_module('qa_venv_usage')


class CleanupTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix='qa-cleanup-')
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        self.root = self.work / 'allowed'
        self.root.mkdir()
        self.source = self.root / 'source with spaces'
        shutil.copytree(FIXTURE, self.source)
        self.env = self.source / 'quality/.venv'
        (self.env / 'bin').mkdir(parents=True)
        (self.env / 'pyvenv.cfg').write_text('home = /fixture\n')
        (self.env / 'bin/tool').write_bytes(b'fixture tools\0')
        self.cache = self.work / 'protected-cache'
        self.cache.write_bytes(b'cached bytes')
        (self.env / 'bin/python').symlink_to(self.cache)
        self.output = self.work / 'proof'
        self.review = self.work / 'review.json'
        self.review.write_text(json.dumps({'candidates': [{'environment': str(self.env)}]}))
        self.authorization = self.work / 'authorization.json'
        self.authorization.write_text(json.dumps({'scope': 'standing-automatic-cleanup-of-unused-reproducible-QA-outputs',
                                                  'approved_categories': ['ignored-quality-venv'], 'allowed_root': str(self.root)}))
        usage = mock.patch.object(MODULE, 'observe_usage', return_value={'fixture_only': True})
        self.usage = usage.start()
        self.addCleanup(usage.stop)

    def run_cleanup(self, apply: bool = False) -> dict[str, Any]:
        return MODULE.cleanup(self.review, self.root, [self.cache], self.output,
                              'fixture-engine', self.authorization if apply else None, apply)

    def test_preview_preserves_everything_and_apply_removes_only_the_ignored_environment(self) -> None:
        source = MODULE.source_state(self.source)
        preview = self.run_cleanup()
        self.assertEqual(preview['status'], 'dry-run')
        self.assertEqual(preview['removed'], [])
        self.assertTrue((self.env / 'bin/tool').exists())
        self.output = self.work / 'applied'
        result = self.run_cleanup(True)
        self.assertEqual(result['status'], 'completed-approved-QA-venv-removal')
        self.assertEqual(len(result['removed']), 1)
        self.assertEqual(list(self.env.iterdir()), [])
        self.assertEqual(MODULE.source_state(self.source), source)
        self.assertEqual(self.cache.read_bytes(), b'cached bytes')
        self.assertTrue((self.output / 'receipt.json').is_file())

    def test_authorization_is_required_scoped_and_root_bound(self) -> None:
        with self.assertRaisesRegex(ValueError, 'authorization record'):
            MODULE.cleanup(self.review, self.root, [self.cache], self.output, 'fixture', apply=True)
        original = json.loads(self.authorization.read_text())
        cases = [({'scope': 'other'}, 'not in the supplied authorization'),
                 ({'approved_categories': []}, 'not in the supplied authorization'),
                 ({'allowed_root': '/other'}, 'allowed root differs')]
        for changed, message in cases:
            self.authorization.write_text(json.dumps(dict(original, **changed)))
            with self.assertRaisesRegex(ValueError, message):
                self.run_cleanup(True)
        self.assertTrue((self.env / 'bin/tool').exists())

    def test_boundaries_duplicates_and_existing_evidence_refuse(self) -> None:
        self.output.mkdir()
        with self.assertRaisesRegex(ValueError, 'existing cleanup evidence'):
            self.run_cleanup(True)
        self.output.rmdir()
        with self.assertRaisesRegex(ValueError, 'protected path'):
            MODULE.cleanup(self.review, self.root, [self.source], self.output, 'fixture')
        alias = self.root / 'alias'
        alias.symlink_to(self.env)
        cases = [[str(alias)], [str(self.env), str(self.env)], ['/tmp']]
        for paths in cases:
            self.review.write_text(json.dumps({'candidates': [{'environment': path} for path in paths]}))
            with self.assertRaises(ValueError):
                self.run_cleanup(True)
        self.assertTrue((self.env / 'bin/tool').exists())

    def test_required_sources_ignore_rule_and_nested_checkouts_are_preserved(self) -> None:
        (self.source / 'AGENTS.md').unlink()
        with self.assertRaisesRegex(AssertionError, 'Owning source and lock'):
            self.run_cleanup(True)
        (self.source / 'AGENTS.md').write_text('fixture rules\n')
        (self.source / '.gitignore').write_text('')
        with self.assertRaises(subprocess.SubprocessError):
            self.run_cleanup(True)
        (self.source / '.gitignore').write_text('quality/.venv/\n')
        (self.env / '.git').mkdir()
        with self.assertRaisesRegex(ValueError, 'versioned source checkout'):
            self.run_cleanup(True)
        self.assertTrue((self.env / 'bin/tool').exists())

    def test_shared_cache_inodes_special_files_and_missing_recreation_metadata_refuse(self) -> None:
        link = self.env / 'cache-link'
        os.link(self.cache, link)
        with self.assertRaisesRegex(AssertionError, 'shared cache inodes'):
            self.run_cleanup(True)
        link.unlink()
        fifo = self.env / 'fifo'
        os.mkfifo(fifo)
        with self.assertRaisesRegex(AssertionError, 'Only directories'):
            self.run_cleanup(True)
        fifo.unlink()
        (self.source / 'quality/pyproject.toml').unlink()
        with self.assertRaisesRegex(ValueError, 'Recreation project metadata'):
            self.run_cleanup(True)

    def test_late_usage_and_snapshot_changes_stop_before_deletion(self) -> None:
        self.usage.side_effect = [{}, ValueError('became busy')]
        with self.assertRaisesRegex(ValueError, 'became busy'):
            self.run_cleanup(True)
        self.assertTrue((self.env / 'bin/tool').exists())
        self.assertEqual(json.loads((self.output / 'failure.json').read_text())['removed'], [])
        self.output = self.work / 'changed-tree'

        def alter_tree(*_arguments: object) -> dict[str, object]:
            if self.usage.call_count == 2:
                (self.env / 'bin/tool').write_bytes(b'new bytes')
            return {}

        self.usage.reset_mock(side_effect=True)
        self.usage.side_effect = alter_tree
        with self.assertRaisesRegex(ValueError, 'environment or owning source changed'):
            self.run_cleanup(True)
        self.assertTrue((self.env / 'bin/tool').exists())

    def test_review_and_authorization_changes_stop_before_deletion(self) -> None:
        for name in ['review', 'authorization']:
            self.output = self.work / ('changed-' + name)
            self.usage.reset_mock(side_effect=True)

            def alter_input(*_arguments: object, selected: str = name) -> dict[str, object]:
                if self.usage.call_count == 2:
                    with getattr(self, selected).open('a') as stream:
                        stream.write('\n')
                return {}

            self.usage.side_effect = alter_input
            with self.assertRaisesRegex(ValueError, 'Cleanup inputs changed'):
                self.run_cleanup(True)
            self.assertTrue((self.env / 'bin/tool').exists())

    def test_removal_failure_is_fatal_and_preserves_failure_evidence(self) -> None:
        with mock.patch.object(MODULE.shutil, 'rmtree', side_effect=OSError('fixture removal failed')), \
             self.assertRaisesRegex(OSError, 'fixture removal failed'):
            self.run_cleanup(True)
        self.assertEqual(json.loads((self.output / 'failure.json').read_text())['status'], 'failed')
        self.assertFalse((self.output / 'receipt.json').exists())
        self.assertTrue((self.env / 'bin/tool').exists())

    def test_deletion_requires_symlink_resistance_and_unchanged_source(self) -> None:
        with mock.patch.object(MODULE.shutil.rmtree, 'avoids_symlink_attacks', False), \
             self.assertRaisesRegex(ValueError, 'Symlink-resistant deletion'):
            self.run_cleanup(True)
        self.assertTrue((self.env / 'bin/tool').exists())
        self.output = self.work / 'changed-source'
        original = MODULE.shutil.rmtree

        def change_source(path: Path) -> None:
            original(path)
            (self.source / 'AGENTS.md').write_text('unexpected concurrent change\n')

        with mock.patch.object(MODULE.shutil, 'rmtree', side_effect=change_source), \
             self.assertRaisesRegex(ValueError, 'Owning versioned source or lock changed'):
            self.run_cleanup(True)
        self.assertFalse((self.output / 'receipt.json').exists())

    def test_optimized_execution_cannot_disable_the_required_validator(self) -> None:
        result = subprocess.run([sys.executable, '-O', '-B', str(OWNER / 'cleanup-qa-venvs.py'),
                                 '--review', str(self.review), '--root', str(self.root), '--directory', str(self.output),
                                 '--protect', str(self.cache)], capture_output=True, text=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Optimization disables prerequisite safety assertions', result.stderr)
        self.assertTrue((self.env / 'bin/tool').exists())


class UsageTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix='qa-usage-')
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        self.path = self.work / 'source with spaces/quality/.venv'
        self.path.mkdir(parents=True)
        self.proc = self.work / 'proc'
        (self.proc / 'self').mkdir(parents=True)
        (self.proc / 'self/mountinfo').write_text('1 0 0:1 / / rw - ext4 fixture rw\n')
        self.process = self.proc / '101'
        (self.process / 'fd').mkdir(parents=True)
        (self.process / 'cmdline').write_bytes(b'python\0')
        (self.process / 'maps').write_bytes(b'')
        for name, target in [('cwd', '/other'), ('exe', '/bin/python'), ('fd/0', '/dev/null')]:
            (self.process / name).symlink_to(target)

    def test_observation_failures_and_malformed_json_fail_closed(self) -> None:
        for status, stdout, stderr in [(1, '[]', ''), (0, '[]', 'warning'), (0, '{}', ''), (0, '[1]', '')]:
            result = subprocess.CompletedProcess(['fixture'], status, stdout, stderr)
            with mock.patch.object(USAGE.subprocess, 'run', return_value=result), self.assertRaises(ValueError):
                USAGE.command_json(['fixture'])
        result = subprocess.CompletedProcess(['fixture'], 0, '[]', '')
        with mock.patch.object(USAGE.subprocess, 'run', return_value=result):
            self.assertEqual(USAGE.command_json(['fixture']), [])

    def test_known_units_require_zero_main_and_control_pids(self) -> None:
        state = {'Id': 'webgpu-fixture.service', 'ActiveState': 'active', 'SubState': 'exited', 'MainPID': '0', 'ControlPID': '0'}
        for key, value in [('MainPID', '12'), ('ControlPID', '9'), ('ActiveState', 'activating')]:
            bad = dict(state, **{key: value})
            with mock.patch.object(USAGE, 'command_json', return_value=[{'unit': state['Id']}]), \
                 mock.patch.object(USAGE, 'checked_output', return_value='\n'.join(f'{k}={v}' for k, v in bad.items())), \
                 self.assertRaisesRegex(ValueError, 'unit is active'):
                USAGE.idle_units()
        with mock.patch.object(USAGE, 'command_json', return_value=[{'unit': state['Id']}]), \
             mock.patch.object(USAGE, 'checked_output', return_value='\n'.join(f'{k}={v}' for k, v in state.items())):
            self.assertEqual(USAGE.idle_units(), [state])

    def test_container_and_buildkit_use_states_are_required(self) -> None:
        idle = {'ID': 'a' * 64, 'Status': 'Created'}
        failures = [([dict(idle, Status='Up 1 second')], []), ([dict(idle, ID='short')], []),
                    ([idle], [{'inUse': True}]), ([idle], [{}]),
                    ([dict(idle, Labels=str(self.path.parent.parent))], [])]
        for containers, records in failures:
            with mock.patch.object(USAGE, 'command_json', side_effect=[containers, records]), self.assertRaises(ValueError):
                USAGE.idle_engines([self.path], 'fixture')
        with mock.patch.object(USAGE, 'command_json', side_effect=[[idle], [{'inUse': False}]]):
            self.assertEqual(USAGE.idle_engines([self.path], 'fixture')['containers'], 1)

    def test_process_arguments_maps_locations_and_descriptors_block_the_combined_observer(self) -> None:
        for name in ['cmdline', 'maps', 'cwd', 'fd/0']:
            target = self.process / name
            original = target.readlink() if target.is_symlink() else target.read_bytes()
            if target.is_symlink():
                target.unlink()
                target.symlink_to(self.path.parent.parent)
            else:
                data = os.fsencode(self.path.parent.parent)
                target.write_bytes(data.replace(b' ', b'\\040') if name == 'maps' else data + b'\0')
            with mock.patch.object(USAGE, 'idle_units', return_value=[]), \
                 mock.patch.object(USAGE, 'idle_engines', return_value={}), self.assertRaisesRegex(ValueError, 'in use by PID'):
                USAGE.observe_usage([self.path], 'fixture', self.proc)
            if target.is_symlink():
                target.unlink()
                target.symlink_to(original)
            else:
                target.write_bytes(cast(bytes, original))

    def test_mounts_and_incomplete_live_processes_refuse(self) -> None:
        mount = str(self.path / 'mounted').replace(' ', '\\040')
        (self.proc / 'self/mountinfo').write_text(f'1 0 0:1 / {mount} rw - ext4 fixture rw\n')
        with mock.patch.object(USAGE, 'idle_units', return_value=[]), \
             mock.patch.object(USAGE, 'idle_engines', return_value={}), self.assertRaisesRegex(ValueError, 'contains a mount'):
            USAGE.observe_usage([self.path], 'fixture', self.proc)
        (self.process / 'maps').unlink()
        with self.assertRaisesRegex(ValueError, 'incomplete use observations'):
            USAGE.idle_processes([self.path], self.proc)


if __name__ == '__main__':
    unittest.main()
