#!/usr/bin/env python3
"""Exercise ignored-tree retention and refusal with filesystem doubles; no actual host reclamation or reboot guarantee."""

from __future__ import annotations

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(sys.argv.pop(1))
FIXTURE = Path(sys.argv.pop(1))
SPEC = importlib.util.spec_from_file_location('quality_venv_relocation', SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RelocationTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix='quality-venv-')
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        self.repo = self.work / 'source'
        shutil.copytree(FIXTURE, self.repo)
        self.source = self.repo / 'quality/.venv'
        (self.source / 'bin').mkdir(parents=True)
        (self.source / 'pyvenv.cfg').write_text('home = /synthetic\n')
        (self.source / 'bin/tool').write_bytes(b'original tool bytes\0')
        (self.source / 'bin/tool').chmod(0o751)
        (self.source / 'bin/python').symlink_to('tool')
        self.target = self.work / 'ant-quality-venv-retained'
        self.output = self.work / 'proof'

    def test_literal_quality_environment_and_owning_source_are_required(self) -> None:
        MODULE.validate_source(self.source)
        alias = self.work / 'alias'
        alias.symlink_to(self.source)
        with self.assertRaisesRegex(AssertionError, 'literal and absolute'):
            MODULE.validate_source(alias)
        wrong = self.source.with_name('other')
        self.source.rename(wrong)
        with self.assertRaisesRegex(AssertionError, 'quality virtual environment'):
            MODULE.validate_source(wrong)
        wrong.rename(self.source)
        for path in [self.repo / 'AGENTS.md', self.repo / 'quality/uv.lock']:
            original = path.read_bytes()
            path.unlink()
            with self.assertRaisesRegex(AssertionError, 'Owning source and lock'):
                MODULE.validate_source(self.source)
            path.write_bytes(original)

    def test_unignored_or_versioned_environments_refuse(self) -> None:
        (self.repo / '.gitignore').write_text('')
        with self.assertRaises(subprocess.CalledProcessError):
            MODULE.validate_source(self.source)
        (self.repo / '.gitignore').write_text('quality/.venv/\n')
        subprocess.run(['git', '-C', str(self.repo), 'add', '--force', 'quality/.venv/pyvenv.cfg'], check=True)
        with self.assertRaisesRegex(AssertionError, 'versioned files'):
            MODULE.validate_source(self.source)

    def test_destinations_evidence_and_filesystem_requirements(self) -> None:
        device = self.source.stat().st_dev
        with mock.patch.object(MODULE, 'filesystem', return_value=(device + 1, {'tmpfs'})):
            MODULE.validate_target(self.source, self.target, self.output)
            alias = self.work / 'parent-alias'
            alias.symlink_to(self.work, target_is_directory=True)
            with self.assertRaisesRegex(AssertionError, 'literal and absolute'):
                MODULE.validate_target(self.source, alias / 'ant-quality-venv-target', self.output)
            for path, message in [(self.target, 'existing destinations'), (self.output, 'existing relocation evidence')]:
                path.mkdir()
                with self.assertRaisesRegex(AssertionError, message):
                    MODULE.validate_target(self.source, self.target, self.output)
                path.rmdir()
            with self.assertRaisesRegex(AssertionError, 'existing destinations'):
                MODULE.validate_target(self.source, self.work / 'unreviewed-name', self.output)
        for value in [(device, {'tmpfs'}), (device + 1, {'overlay'}), (device + 1, {'tmpfs', 'overlay'})]:
            with self.subTest(filesystem=value), mock.patch.object(MODULE, 'filesystem', return_value=value), self.assertRaisesRegex(AssertionError, 'different existing tmpfs'):
                MODULE.validate_target(self.source, self.target, self.output)
        with mock.patch.object(MODULE.subprocess, 'check_output', return_value='tmpfs\ntmpfs\n'):
            self.assertEqual(MODULE.filesystem(self.work), (self.work.stat().st_dev, {'tmpfs'}))

    def test_shared_inodes_and_special_files_refuse(self) -> None:
        original = self.source / 'bin/tool'
        alias = self.source / 'bin/alias'
        os.link(original, alias)
        with self.assertRaisesRegex(AssertionError, 'shared cache inodes'):
            MODULE.allocated_regular_bytes(self.source)
        alias.unlink()
        os.mkfifo(self.source / 'fifo')
        with self.assertRaisesRegex(AssertionError, 'Only directories'):
            MODULE.allocated_regular_bytes(self.source)

    def test_retention_real_tar_bytes_modes_links_and_empty_mountpoint(self) -> None:
        before = MODULE.tree_digest(self.source)
        with mock.patch.object(MODULE, 'validate_target'):
            result = MODULE.relocate(self.source, self.target, self.output)
        self.assertEqual(MODULE.tree_digest(self.target), before)
        self.assertEqual((self.target / 'bin/tool').read_bytes(), b'original tool bytes\0')
        self.assertEqual((self.target / 'bin/tool').stat().st_mode & 0o777, 0o751)
        self.assertEqual(os.readlink(self.target / 'bin/python'), 'tool')
        self.assertEqual(list(self.source.iterdir()), [])
        self.assertEqual(result['before_gnu_tar_sha256'], before)
        self.assertTrue((self.output / 'receipt.json').is_file())

    def test_tar_failure_cannot_become_an_empty_archive_proof(self) -> None:
        with self.assertRaisesRegex(RuntimeError, 'Environment archive failed'):
            MODULE.tree_digest(self.work / 'absent')

    def test_archive_fingerprint_observes_contents_and_modes(self) -> None:
        tool = self.source / 'bin/tool'
        original = tool.read_bytes()
        metadata = tool.stat()
        before = MODULE.tree_digest(self.source)
        tool.write_bytes(b'X' + original[1:])
        os.utime(tool, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
        self.assertNotEqual(MODULE.tree_digest(self.source), before)
        tool.write_bytes(original)
        os.utime(tool, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
        self.assertEqual(MODULE.tree_digest(self.source), before)
        tool.chmod(0o750)
        self.assertNotEqual(MODULE.tree_digest(self.source), before)

    def test_failed_archive_or_insufficient_headroom_preserves_original(self) -> None:
        with mock.patch.object(MODULE, 'validate_target'), mock.patch.object(MODULE, 'tree_digest', side_effect=RuntimeError('archive failed')), self.assertRaisesRegex(RuntimeError, 'archive failed'):
            MODULE.relocate(self.source, self.target, self.output)
        self.assertTrue((self.source / 'bin/tool').is_file())
        self.assertFalse(self.target.exists())
        empty = mock.Mock(f_bavail=0, f_frsize=4096)
        with mock.patch.object(MODULE, 'validate_target'), mock.patch.object(MODULE.os, 'statvfs', return_value=empty), self.assertRaisesRegex(AssertionError, 'tmpfs headroom'):
            MODULE.relocate(self.source, self.target, self.output)
        self.assertFalse(self.output.exists())

    def test_incomplete_move_or_changed_retained_bytes_cannot_publish_receipt(self) -> None:
        with mock.patch.object(MODULE, 'validate_target'), mock.patch.object(MODULE.shutil, 'move'), self.assertRaisesRegex(AssertionError, 'did not complete'):
            MODULE.relocate(self.source, self.target, self.output)
        self.assertFalse((self.output / 'receipt.json').exists())
        self.output.joinpath('invocation.json').unlink()
        self.output.rmdir()
        with mock.patch.object(MODULE, 'validate_target'), mock.patch.object(MODULE, 'tree_digest', side_effect=['before', 'changed']), self.assertRaisesRegex(AssertionError, 'bytes or metadata differ'):
            MODULE.relocate(self.source, self.target, self.output)
        self.assertTrue((self.target / 'bin/tool').is_file())
        self.assertFalse((self.output / 'receipt.json').exists())


if __name__ == '__main__':
    unittest.main()
