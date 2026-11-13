#!/usr/bin/env python3
"""Check preserved tool closures and refusal behavior with doubles; no real cleanup or image acceptance."""

import ast
import copy
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
TOOLS = ROOT / 'linux/scripts/local-proof'
HOST = ROOT / 'linux/host-config'


class ToolTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix='ant-local-proof-')
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.env = dict(os.environ, HOME=str(self.work), LC_ALL='C', PYTHONDONTWRITEBYTECODE='1')

    def run_tool(self, path: Path, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(path), *args], env=self.env, capture_output=True, text=True, timeout=30, check=False)

    def test_inventory_retains_every_canonical_file_and_machine_portability(self) -> None:
        inventory = json.loads((TOOLS / 'inventory.json').read_text())
        self.assertEqual(len({row['name'] for row in inventory['scripts']}), len(inventory['scripts']))
        selected = [row for row in inventory['scripts'] if row['classification'] == 'versioned']
        self.assertGreater(len(selected), 40)
        for row in selected:
            with self.subTest(tool=row['name']):
                path = ROOT / row['canonical']
                self.assertTrue(path.is_file())
                self.assertNotIn('/home/bigjuicyjones', path.read_text())
                self.assertNotIn('/logs/', str(path.relative_to(ROOT)))
                if path.suffix == '.py':
                    ast.parse(path.read_text())

    def test_cross_probe_receipt_refusals(self) -> None:
        result = self.run_tool(TOOLS / 'test-probe-cross-clang-image.py', '--source', str(ROOT))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['refusal_controls'], 26)

    def test_sdk_parent_receipt_refusals(self) -> None:
        result = self.run_tool(TOOLS / 'test-native-oci-cross-qualification.py')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['refusal_controls'], 9)

    def fake_systemd(self) -> None:
        binary = self.work / 'bin'
        binary.mkdir()
        for name in ['systemctl', 'systemd-run']:
            path = binary / name
            path.symlink_to(Path(__file__).with_name('operational_systemd_fixture.py'))
        self.env['PATH'] = str(binary) + os.pathsep + os.environ['PATH']

    def test_cleanup_requires_existing_owner_authorization_before_launch(self) -> None:
        self.fake_systemd()
        policy = self.work / 'policy.md'
        policy.write_text('Unrelated operational notes.\n')
        result = self.run_tool(HOST / 'autonomous-safe-prune.py', 'launch', '--directory', str(self.work / 'output'),
                               '--unit', 'webgpu-safe-prune-fixture.service', '--authorization', str(policy))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('AssertionError', result.stderr)
        self.assertFalse((self.work / 'output').exists())

    def test_cleanup_refuses_mid_build_budget_below_100(self) -> None:
        policy = self.work / 'policy.md'
        policy.write_text('agents may run the existing `linux/host-config/prune-safe.sh` autonomously')
        result = self.run_tool(HOST / 'autonomous-safe-prune.py', 'launch', '--directory', str(self.work / 'output'),
                               '--unit', 'webgpu-safe-prune-fixture.service', '--authorization', str(policy), '--keep-gb', '99')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('AssertionError', result.stderr)
        self.assertFalse((self.work / 'output').exists())

    def cleanup_fixture(self) -> dict:
        snapshot = {'cachemount_ids': ['cache-a', 'cache-b'], 'image_records': [dict(zip(
            ['Repository', 'Tag', 'Digest', 'ID', 'Platform'], ['local/tool', 'keep', 'sha256:a', 'sha256:a', 'linux/amd64']))],
                    'running_containers': [], 'buildkit_record_types': {'regular': {'in_use': 0}},
                    'disk_free_bytes': 200 * 1024**3}
        for name in ['before', 'after']:
            (self.work / name).mkdir()
            (self.work / name / 'snapshot.json').write_text(json.dumps(snapshot))
        (self.work / 'prune.exit-status').write_text('0\n')
        (self.work / 'prune.log').write_text('fixture only\n')
        (self.work / 'disk.sh').write_text('_disk_guard_free_gb() { printf "180\\n"; }\n')
        return copy.deepcopy(snapshot)

    def verify_cleanup(self, *extra: str) -> subprocess.CompletedProcess:
        return self.run_tool(HOST / 'verify-safe-prune.py', '--directory', str(self.work), '--keep-gb', '120',
                             '--disk-helper', str(self.work / 'disk.sh'), *extra)

    def test_cleanup_receipt_positive_control(self) -> None:
        self.cleanup_fixture()
        result = self.verify_cleanup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)['reserve_satisfied'])

    def test_cleanup_receipt_refuses_missing_cachemount(self) -> None:
        snapshot = self.cleanup_fixture()
        snapshot['cachemount_ids'].pop()
        (self.work / 'after/snapshot.json').write_text(json.dumps(snapshot))
        result = self.verify_cleanup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('AssertionError', result.stderr)
        self.assertFalse((self.work / 'proof.json').exists())

    def test_cleanup_receipt_refuses_changed_image(self) -> None:
        snapshot = self.cleanup_fixture()
        snapshot['image_records'][0]['Digest'] = 'sha256:changed'
        (self.work / 'after/snapshot.json').write_text(json.dumps(snapshot))
        result = self.verify_cleanup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('AssertionError', result.stderr)
        self.assertFalse((self.work / 'proof.json').exists())

    def test_idle_cleanup_receipt_refuses_busy_store(self) -> None:
        snapshot = self.cleanup_fixture()
        snapshot['buildkit_record_types']['regular']['in_use'] = 1
        (self.work / 'after/snapshot.json').write_text(json.dumps(snapshot))
        result = self.verify_cleanup('--idle-store')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('AssertionError', result.stderr)
        self.assertFalse((self.work / 'proof.json').exists())

    def checkpoint_fixture(self) -> list[str]:
        self.fake_systemd()
        units = {}
        command = []
        for index in [1, 2]:
            directory = self.work / f'preflight-{index}'
            directory.mkdir()
            invocation = {'revision': str(index) * 40, 'run_id': f'owned-{index}', 'unit': f'source-{index}.service',
                          'source': str(directory / 'source'), 'full_registry': 100 + index}
            directory.with_name(directory.name + '-invocation.json').write_text(json.dumps(invocation))
            (directory / 'run.json').write_text(json.dumps({'source_revision': invocation['revision'],
                'owner_run_id': invocation['run_id'], 'status': 'running'}))
            units[invocation['unit']] = {'Id': invocation['unit'], 'LoadState': 'loaded', 'ActiveState': 'activating',
                                        'SubState': 'start', 'MainPID': str(index), 'Result': 'success', 'ExecMainStatus': '0'}
            command += ['--preflight', str(directory)]
        fixture = self.work / 'units.json'
        fixture.write_text(json.dumps(units))
        self.env['OPERATIONAL_UNIT_FIXTURE'] = str(fixture)
        (self.work / 'state.json').write_text(json.dumps({'accepted_checkpoint': 'preserve', 'live_units': ['stale']}))
        (self.work / 'CURRENT.md').write_text('Historical evidence must remain.\n')
        return command + ['--state', str(self.work / 'state.json'), '--markdown', str(self.work / 'CURRENT.md')]

    def test_checkpoint_retains_both_live_units_and_unrelated_evidence(self) -> None:
        command = self.checkpoint_fixture()
        for index in [1, 2]:
            result = self.run_tool(TOOLS / 'checkpoint-proof-runs.py', *command, '--output', str(self.work / f'checkpoint-{index}.json'))
            self.assertEqual(result.returncode, 0, result.stderr)
            state = json.loads((self.work / 'state.json').read_text())
            self.assertEqual(len(state['live_units']), 2)
            self.assertEqual(state['accepted_checkpoint'], 'preserve')
            self.assertFalse(state['operational_runs']['acceptance_claimed'])
            text = (self.work / 'CURRENT.md').read_text()
            self.assertEqual(text.count('<!-- operational-runs-current:start -->'), 1)
            self.assertIn('Historical evidence must remain.', text)

    def test_checkpoint_refuses_mismatched_run_identity_before_writing(self) -> None:
        command = self.checkpoint_fixture()
        path = self.work / 'preflight-2/run.json'
        record = json.loads(path.read_text())
        record['owner_run_id'] = 'another-owner'
        path.write_text(json.dumps(record))
        result = self.run_tool(TOOLS / 'checkpoint-proof-runs.py', *command, '--output', str(self.work / 'checkpoint.json'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('AssertionError', result.stderr)
        self.assertFalse((self.work / 'checkpoint.json').exists())
        self.assertEqual(json.loads((self.work / 'state.json').read_text())['live_units'], ['stale'])


if __name__ == '__main__':
    unittest.main()
