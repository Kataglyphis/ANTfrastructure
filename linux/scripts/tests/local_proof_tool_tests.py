#!/usr/bin/env python3
"""Check preserved tool closures and refusal behavior with doubles; no real cleanup or image acceptance."""

import ast
import copy
import hashlib
import json
import os
import runpy
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

    def fake_tool(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.symlink_to(Path(__file__).with_name('operational_systemd_fixture.py'))

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
        self.assertEqual(json.loads(result.stdout)['refusal_controls'], 27)

    def test_sdk_parent_receipt_refusals(self) -> None:
        for extra in [(), ('--current-profile',)]:
            with self.subTest(profile=extra):
                result = self.run_tool(TOOLS / 'test-native-oci-cross-qualification.py', *extra)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)['refusal_controls'], 9)

    def test_current_compiler_profile_requires_explicit_complete_scope(self) -> None:
        subject = runpy.run_path(str(TOOLS / 'proof_subject.py'))['image_subject']
        base = {'local_image':'ant-local/webgpu-fixture:cross-compiler-amd64', 'unit':'fixture.service'}
        self.assertFalse(subject(base)['cross_required'])
        self.assertTrue(subject(dict(base, launcher_contract=2))['cross_required'])
        current = dict(base, source_proofs={})
        for profile in ['', 'native-only', 'compiler-cross-cpu-unknown']:
            for candidate in [base, current]:
                with self.subTest(profile=profile, current=candidate is current), self.assertRaisesRegex(AssertionError, 'profile'):
                    subject(dict(candidate, image_qualification_profile=profile))
        with self.assertRaisesRegex(AssertionError, 'complete compiler CPU profile'):
            subject(dict(current, image_qualification_profile=None))
        with self.assertRaisesRegex(AssertionError, 'complete compiler CPU profile'):
            subject(current)
        self.assertTrue(subject(dict(current, image_qualification_profile='compiler-cross-cpu'))['cross_required'])

    def test_sdk_image_profile_refusals(self) -> None:
        result = self.run_tool(TOOLS / 'test-sdk-image-profile.py', '--source', str(ROOT))
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt['refusal_controls'], 70)
        self.assertEqual(receipt['positive_controls'], 6)
        self.assertFalse(receipt['actual_image_acceptance'])

    def sdk_transport_fixture(self) -> dict:
        self.fake_systemd()
        data = runpy.run_path(str(TOOLS / 'sdk_profile_fixture.py'))['producer_fixture']()
        data['plan'].update(source=str(ROOT), expected_pins={'GCC_VERSION':'16.2.0','LLVM_RELEASE':'23.1.5'})
        data['invocation'].update(source=str(ROOT), output=str(self.work))
        data['invocation']['command'][-9] = str(ROOT / 'linux/scripts/build-cross-stage.sh')
        data['invocation']['command'][-1] = str(self.work / 'logs')
        for name in ['parent','full','plan']:
            (self.work / (name + '.json')).write_text(json.dumps(data[name]))
        data['invocation'].update(parent_OCI_proof=str(self.work / 'parent.json'), SDK_source_full_preflight_proof=str(self.work / 'full.json'))
        (self.work / 'sdk-invocation.json').write_text(json.dumps(data['invocation']))
        original = self.work / 'original'
        original.mkdir()
        original.joinpath('invocation.json').write_text(json.dumps({'input_sha256':{'plain-load.py':hashlib.sha256((TOOLS / 'probe-soname-load.py').read_bytes()).hexdigest()}}))
        for name in ['git','nerdctl']:
            binary = self.work / ('bin/git' if name == 'git' else '.local/bin/nerdctl')
            self.fake_tool(binary)
        self.env.update(OPERATIONAL_GIT_REVISION='synthetic-fixture', OPERATIONAL_IMAGE_FIXTURE=str(self.work / 'image.json'),
                        OPERATIONAL_UNIT_FIXTURE=str(self.work / 'units.json'))
        return data

    def test_sdk_image_profile_launch_transport(self) -> None:
        data = self.sdk_transport_fixture()
        terminal = {'LoadState':'loaded','ActiveState':'active','SubState':'exited','MainPID':'0','ExecMainStatus':'0','Result':'success'}
        for kind in ['compiler','sdk','current']:
            sdk = kind == 'sdk'
            with self.subTest(kind=kind):
                profile = copy.deepcopy(data['plan'])
                if kind == 'current':
                    profile.pop('launcher_contract')
                    profile.update(source_proofs={}, image_qualification_profile='compiler-cross-cpu')
                (self.work / 'plan.json').write_text(json.dumps(profile))
                unit = 'webgpu-' + ('sdk' if sdk else 'compiler') + '-image-qualification-' + kind + '.service'
                units = {data['plan']['unit']:terminal, data['invocation']['unit']:terminal, unit:{'LoadState':'not-found'}}
                (self.work / 'units.json').write_text(json.dumps(units))
                image = data['invocation']['image'] if sdk else data['plan']['local_image']
                (self.work / 'image.json').write_text(json.dumps([{'RepoDigests':[image.rsplit(':',1)[0] + '@sha256:' + 'a' * 64],
                                                                  'Id':'sha256:' + 'b' * 64, 'Config':{'Env':[]}}]))
                self.env['OPERATIONAL_EXPECTED_IMAGE'] = image
                output = self.work / kind
                arguments = ['launch','--plan',str(self.work / 'plan.json'),'--output',str(output),'--unit',unit,
                             '--original-qualification',str(self.work / 'original'),'--plain-load-probe',str(TOOLS / 'probe-soname-load.py')]
                if sdk:
                    arguments += ['--sdk-invocation',str(self.work / 'sdk-invocation.json')]
                result = self.run_tool(TOOLS / 'compiler-image-qualification.py',*arguments)
                self.assertEqual(result.returncode,0,result.stderr)
                record = json.loads((output / 'invocation.json').read_text())
                self.assertEqual(record['image'],image)
                self.assertEqual(record['subject']['native_prefix'],'/opt/llvm-target' if sdk else '/opt/llvm-target-amd64')
                if sdk:
                    for field, name in [('sdk_invocation_sha256','sdk-invocation.json'), ('compiler_parent_sha256','parent.json'), ('source_proof_sha256','full.json')]:
                        self.assertEqual(record['subject'][field],hashlib.sha256((self.work / name).read_bytes()).hexdigest())
                self.assertEqual(record['sdk_native_checks_required'],sdk)
                self.assertEqual(record['cross_wrapper_checks_required'],not sdk)
                self.assertIn('/qualify-with-cross.sh',record['command'])
                self.assertEqual(record['command'][-1],'sdk-amd64' if sdk else '/opt/llvm-target-amd64')
                self.assertEqual(record['command'].count('--env'),1)

    def fake_systemd(self) -> None:
        binary = self.work / 'bin'
        binary.mkdir()
        for name in ['systemctl', 'systemd-run']:
            path = binary / name
            self.fake_tool(path)
        self.env['PATH'] = str(binary) + os.pathsep + os.environ['PATH']

    def test_direct_failure_audit_preserves_only_observed_assertion_failures(self) -> None:
        self.fake_systemd()
        self.fake_tool(self.work / '.local/bin/nerdctl')
        unit = 'source-failed-fixture.service'
        terminal = {'Id':unit, 'LoadState':'loaded', 'ActiveState':'failed', 'SubState':'failed',
                    'MainPID':'0', 'ExecMainStatus':'23', 'Result':'exit-code', 'ExecMainExitTimestampMonotonic':'1'}
        (self.work / 'units.json').write_text(json.dumps({unit:terminal}))
        (self.work / 'containers.jsonl').write_text('')
        self.env.update(OPERATIONAL_UNIT_FIXTURE=str(self.work / 'units.json'),
                        OPERATIONAL_PS_FIXTURE=str(self.work / 'containers.jsonl'))
        for name, marker, preflight in [('missing',False,False), ('late',True,True), ('direct',True,False)]:
            with self.subTest(case=name):
                out = self.work / name
                out.mkdir()
                (out / 'invocation.json').write_text(json.dumps({'unit':unit, 'source':str(ROOT),
                    'owner_label':'org.kataglyphis.migraphx-source', 'run_id':'fixture-run'}))
                (out / 'cleanup.json').write_text(json.dumps({'exit_status':0, 'run_id':'fixture-run'}))
                (out / 'container.cid').write_text('a' * 64)
                (out / 'selected-mutations.json').write_text('[{"id":"not-started"}]')
                (out / 'python-type-tests.log').write_text('1/2 assertion(s) FAILED\n' if marker else 'passed\n')
                if preflight:
                    (out / 'preflight.log').write_text('a later phase ran\n')
                result = self.run_tool(TOOLS / 'audit-failed-source-check.py', '--directory', str(out))
                if name != 'direct':
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('Direct failure cannot' if preflight else 'Missing direct suite', result.stderr)
                    self.assertFalse((out / 'failure-proof.json').exists())
                    continue
                self.assertEqual(result.returncode, 0, result.stderr)
                proof = json.loads((out / 'failure-proof-stopped.json').read_text())
                self.assertEqual(proof['raw_status'], 23)
                self.assertEqual(proof['actual_mutations_passed'], 0)
                self.assertEqual(proof['direct_failed_logs'], ['python-type-tests.log'])
                self.assertFalse(proof['source_accepted'])
                self.assertFalse(proof['mutation_execution_started'])
                self.assertFalse((out / 'mutations.log').exists())

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
