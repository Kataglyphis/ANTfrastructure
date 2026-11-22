#!/usr/bin/env python3
"""Use synthetic receipts and command doubles; no service execution, source provenance or image acceptance."""

import hashlib
import json
import os
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
TOOLS = ROOT / 'linux/scripts/local-proof'


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value), encoding='utf-8')


class CompleteReceiptTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix='ant-complete-receipt-')
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        binary = self.work / 'bin'
        binary.mkdir()
        for name in ['git', 'nerdctl']:
            (binary / name).symlink_to(Path(__file__).with_name('operational_systemd_fixture.py'))
        self.rows = self.work / 'containers.jsonl'
        self.rows.write_text('')
        self.env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
                        OPERATIONAL_GIT_REVISION='synthetic-fixture', OPERATIONAL_PS_FIXTURE=str(self.rows),
                        PYTHONDONTWRITEBYTECODE='1', LC_ALL='C')
        self.output = self.work / 'proof'
        self.output.mkdir()
        self.sequence = 0
        self.cleanup = self.work / 'cleanup with spaces.json'
        save(self.cleanup, {'exit_status': 0, 'run_id': 'fixture-owner'})
        self.stop = shlex.join(['/usr/bin/python3', '/fixture/cleanup.py', '--run-id', 'fixture-owner',
                                '--output', str(self.cleanup)])
        save(self.output / 'run.json', {'status': 'passed', 'command_exit_status': 0, 'cleanup_exit_status': 0,
             'interrupted_exit_status': None, 'finished_at': 'fixture-terminal', 'source_revision': 'synthetic-fixture',
             'owner_run_id': 'fixture-owner', 'source_snapshot': str(ROOT), 'container': 'fixture-container'})
        save(self.work / 'reference.json', {'status': 'passed-complete-Linux-source-preflight-only',
             'source_snapshot': str(ROOT), 'all_default_preflight_groups': ['fixture group'], 'actual_preflight_group_count': 1})
        self.prepare_mutations()
        (self.output / 'container.cid').write_text('a' * 64)

    def prepare_mutations(self) -> None:
        manifest = ROOT / 'docs/scripts/mutations.json'
        entries = json.loads(manifest.read_text())
        self.count = len(entries)
        lines = [f'[{index}/{self.count}] bites {entry["id"]} fixture\n' for index, entry in enumerate(entries, 1)]
        lines += [f'coverage: proved {self.count} of {self.count}: the whole manifest\n',
                  'OK: every recorded mutation is caught by its tests\n']
        mutations = self.output / 'mutations-only.log'
        mutations.write_text(''.join(lines), encoding='utf-8')
        prefix = b'== test-synthetic.sh ==\nAll linux script test suites passed (1 suites, 1 assertions).\n'
        suffix = '\n✓ fixture group\nAll preflight checks passed.\n'.encode()
        log = self.output / 'preflight.log'
        log.write_bytes(prefix + mutations.read_bytes() + suffix)
        save(self.output / 'mutator-extraction.json', {'source_sha256': digest(log), 'start_byte': len(prefix),
             'end_byte_exclusive': len(prefix) + mutations.stat().st_size, 'mutation_job_sha256': digest(mutations)})
        save(self.output / 'mutation-proof-stopped.json', {'status': 'passed-mutation-unit-only', 'unit': 'fixture.service',
             'terminal': {'Id': 'fixture.service', 'LoadState': 'loaded', 'MainPID': '0', 'ExecMainStatus': '0',
                          'Result': 'success', 'ExecMainExitTimestampMonotonic': '1'},
             'stopped': {'MainPID': '0', 'ActiveState': 'inactive'}, 'unique_actual_mutations': self.count,
             'inputs': {str(manifest): digest(manifest), str(mutations): digest(mutations)}})

    def invoke(self, arguments: list[str]) -> subprocess.CompletedProcess[str]:
        self.sequence += 1
        self.proof = self.output / f'case-{self.sequence}.json'
        self.query = self.output / f'case-{self.sequence}-engine-query.json'
        save(self.work / 'proof-invocation.json', {'revision': 'synthetic-fixture', 'run_id': 'fixture-owner',
             'unit': 'fixture.service', 'full_registry': self.count, 'command': ['systemd-run', *arguments]})
        return subprocess.run([sys.executable, str(TOOLS / 'complete-preflight-receipt.py'),
                               '--directory', str(self.output), '--reference', str(self.work / 'reference.json'),
                               '--engine', str(self.work / 'bin/nerdctl'), '--name', self.proof.stem], env=self.env,
                              capture_output=True, text=True, timeout=30, check=False)

    def test_complete_receipt_accepts_equivalent_systemd_property_arguments(self) -> None:
        for arguments in [['--property=ExecStopPost=' + self.stop], ['--property', 'ExecStopPost=' + self.stop],
                          ['-p', 'ExecStopPost=' + self.stop], ['-pExecStopPost=' + self.stop]]:
            with self.subTest(arguments=arguments):
                result = self.invoke(arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
                proof = json.loads(self.proof.read_text())
                self.assertEqual(proof['cleanup_record'], {'exit_status': 0, 'run_id': 'fixture-owner'})
                self.assertTrue(proof['owned_container_absent'])
                self.assertFalse(proof['publication'])
                self.assertEqual(json.loads((self.work / 'proof-invocation.json').read_text())['command'][1:], arguments)

    def test_complete_receipt_refuses_missing_duplicate_or_failed_cleanup(self) -> None:
        for case in ['missing', 'wrong-property', 'duplicate-long', 'duplicate-mixed', 'empty', 'wrong-argv-owner', 'wrong-owner', 'failed']:
            with self.subTest(case=case):
                arguments = ['--property=ExecStopPost=' + self.stop]
                if case == 'missing':
                    arguments = []
                elif case == 'wrong-property':
                    arguments = ['--property=ExecStart=' + self.stop]
                elif case.startswith('duplicate'):
                    arguments += (['--property=ExecStopPost=' + self.stop] if case == 'duplicate-long'
                                  else ['-p', 'ExecStopPost=' + self.stop])
                elif case == 'empty':
                    arguments = ['--property=ExecStopPost=']
                elif case == 'wrong-argv-owner':
                    arguments = ['--property=ExecStopPost=' + self.stop.replace('--run-id fixture-owner', '--run-id wrong-owner')]
                owner = 'wrong-owner' if case == 'wrong-owner' else 'fixture-owner'
                save(self.cleanup, {'exit_status': 17 if case == 'failed' else 0, 'run_id': owner})
                result = self.invoke(arguments)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn('AssertionError' if case != 'empty' else 'ValueError', result.stderr)
                self.assertFalse(self.proof.exists())
                self.assertFalse(self.query.exists())


if __name__ == '__main__':
    unittest.main()
