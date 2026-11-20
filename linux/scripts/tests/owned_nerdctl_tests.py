#!/usr/bin/env python3
"""Check ownership arguments and real exec status with a fake engine; no container, registry, cleanup execution or runtime acceptance."""

from __future__ import annotations

import json
import os
import runpy
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'linux/scripts'))
from owned_nerdctl_args import owned_engine_command

ENTRY = runpy.run_path(str(ROOT / 'linux/scripts/owned-nerdctl.py'))


class OwnedEngineTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix='owned-engine-')
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        self.engine = '/actual/nerdctl'
        self.label = 'org.kataglyphis.normal-runtime'
        self.token = 'd' * 32

    def command(self, args: list[str]) -> list[str]:
        return owned_engine_command(args, self.engine, self.label, self.token)

    def test_each_creation_form_gets_exact_owner_without_losing_arguments(self) -> None:
        for prefix in [['run'], ['create'], ['container', 'run'], ['container', 'create']]:
            tail = ['--rm', '--label', 'other=value', '--env', 'VALUE=with spaces', 'image@sha256:abc', 'argument with spaces']
            original = prefix + tail
            self.assertEqual(self.command(original), [self.engine, *prefix, '--label', self.label + '=' + self.token, *tail])
            self.assertEqual(original, prefix + tail)

    def test_inspect_build_pull_and_noncreating_calls_are_unchanged(self) -> None:
        for args in [['image', 'inspect', 'repo@sha256:abc'], ['build', '--buildkit-host', 'unix:///socket', '--build-arg', 'VALUE=with spaces', '.'],
                     ['pull', '--platform', 'linux/amd64', 'repo@sha256:abc'], ['rm', '--force', 'owned-cid'],
                     ['container', 'inspect', 'cid'], ['--version'], ['--help'], ['-v'], ['-h']]:
            self.assertEqual(self.command(args), [self.engine, *args])

    def test_unreviewed_global_forms_and_empty_commands_refuse(self) -> None:
        for args in [[], ['--namespace', 'other', 'run', 'image'], ['--help', 'run', 'image'], ['--debug', 'create', 'image']]:
            with self.subTest(args=args), self.assertRaises(AssertionError):
                self.command(args)

    def test_label_files_and_explicit_ownership_overrides_refuse(self) -> None:
        for option in [['--label-file', 'file'], ['--label-file=file'], ['--label', self.label + '=foreign'], ['--label=' + self.label + '=foreign'], ['-l', self.label + '=foreign'], ['-l' + self.label + '=foreign'], ['-l=' + self.label + '=foreign']]:
            for prefix in [['run'], ['container', 'create']]:
                with self.subTest(option=option, prefix=prefix), self.assertRaises(AssertionError):
                    self.command([*prefix, *option, 'image'])

    def test_owner_validation_and_absolute_engine_remain_required(self) -> None:
        for label, token in [('invalid', self.token), (self.label, 'not-a-uuid')]:
            with self.subTest(label=label, token=token), self.assertRaises(ValueError):
                owned_engine_command(['run', 'image'], self.engine, label, token)
        with self.assertRaises(AssertionError):
            owned_engine_command(['run', 'image'], 'relative-engine', self.label, self.token)

    def test_entry_execs_real_engine_with_raw_streams_and_status(self) -> None:
        engine = self.work / 'fake-engine'
        engine.write_text('#!/usr/bin/env python3\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\nprint("engine stderr",file=sys.stderr)\nsys.exit(47)\n')
        engine.chmod(0o755)
        environment = dict(os.environ, ANT_RUNTIME_ENGINE=str(engine), ANT_RUNTIME_OWNER_LABEL=self.label, ANT_RUNTIME_RUN_ID=self.token)
        script = ROOT / 'linux/scripts/owned-nerdctl.py'
        for args, expected in [(['run', '--rm', 'image', 'with spaces'], ['run', '--label', self.label + '=' + self.token, '--rm', 'image', 'with spaces']),
                               (['pull', 'repo@sha256:abc'], ['pull', 'repo@sha256:abc'])]:
            result = subprocess.run([sys.executable, str(script), *args], env=environment, capture_output=True, text=True, timeout=30, check=False)
            self.assertEqual(result.returncode, 47)
            self.assertEqual(json.loads(result.stdout), expected)
            self.assertEqual(result.stderr, 'engine stderr\n')

    def test_recursive_engine_is_rejected_before_exec(self) -> None:
        environment = {'ANT_RUNTIME_ENGINE': str(ROOT / 'linux/scripts/owned-nerdctl.py'),
                       'ANT_RUNTIME_OWNER_LABEL': self.label, 'ANT_RUNTIME_RUN_ID': self.token}
        with mock.patch.dict(os.environ, environment), mock.patch.object(sys, 'argv', ['owned-nerdctl.py', 'run', 'image']), \
                mock.patch.object(os, 'execv') as execute, self.assertRaises(AssertionError):
            ENTRY['main']()
        execute.assert_not_called()


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0], *sys.argv[1:]])
