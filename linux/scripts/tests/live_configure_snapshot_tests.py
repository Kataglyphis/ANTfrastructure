#!/usr/bin/env python3
"""Check bounded stable file snapshots with explicit process/unit doubles; no real producer, binary linkage or image acceptance."""

from __future__ import annotations

import json
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import TYPE_CHECKING
from unittest import mock

if TYPE_CHECKING:
    from typing import Any

ROOT = Path(__file__).resolve().parents[3]
TOOLS = ROOT / 'linux/scripts/local-proof'
sys.path.insert(0,str(TOOLS))
SNAPSHOT = runpy.run_path(str(TOOLS / 'snapshot-live-configure.py'))
NAMES = ('CMakeCache.txt','build.ninja','CMakeFiles/rules.ninja','CMakeFiles/CMakeConfigureLog.yaml')


class SnapshotTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix='configure-snapshot-')
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        self.process = self.work / 'process'
        self.process.mkdir()
        (self.process / 'cmdline').write_bytes(b'bash\0/opt/scripts/03-media/build/migraphx/build-image.sh\0/synthetic-work')
        self.relative = Path('tmp/migraphx-source-stack/backend/build')
        self.source = self.process / 'root' / self.relative
        self.write_inputs(self.source)
        self.output = self.work / 'snapshot'
        self.invocation = self.work / 'invocation.json'
        self.invocation.write_text(json.dumps({'unit':'webgpu-normal-gpu-amd64-99999999-1.service','source_revision':'f' * 40}))
        self.unit = 'Id=webgpu-normal-gpu-amd64-99999999-1.service\nLoadState=loaded\nActiveState=activating\nMainPID=456\n'

    def write_inputs(self, root: Path) -> None:
        for index,name in enumerate(NAMES):
            path = root / name
            path.parent.mkdir(parents=True,exist_ok=True)
            path.write_bytes(bytes([index + 65]) * (index + 1))

    def snapshot(self, *, ticks: tuple[str, str] = ('17','17'), pid: int = 123,
                 relative: Path | None = None, output: Path | None = None) -> dict[str, Any]:
        runner = mock.Mock(return_value=subprocess.CompletedProcess([],0,self.unit,''))
        with mock.patch.dict(SNAPSHOT['snapshot'].__globals__,{'START_TICKS':mock.Mock(side_effect=ticks),'checked_run':runner}):
            return SNAPSHOT['snapshot'](self.invocation,pid,relative or self.relative,output or self.output,self.process)

    def test_stable_exact_four_files_and_input_binding(self) -> None:
        before = {name:(self.source / name).read_bytes() for name in NAMES}
        record = self.snapshot()
        self.assertEqual(set(record['sha256']),set(NAMES))
        for name in NAMES:
            self.assertEqual((self.output / name).read_bytes(),before[name])
            self.assertEqual((self.source / name).read_bytes(),before[name])
        self.assertEqual(record['source_revision'],'f' * 40)
        self.assertEqual(record['pid_start_ticks'],'17')
        self.assertEqual(record['invocation_sha256'],SNAPSHOT['sha'](self.invocation))
        self.assertFalse(record['producer_changed'])
        self.assertFalse(record['image_acceptance'])
        self.assertEqual(json.loads((self.output / 'observation.json').read_text()),record)

    def test_dead_or_unrelated_producer_refuses_before_output(self) -> None:
        self.unit = self.unit.replace('activating','inactive').replace('456','0')
        with self.assertRaises(AssertionError):
            self.snapshot()
        self.unit = self.unit.replace('inactive','active').replace('MainPID=0','MainPID=456')
        (self.process / 'cmdline').write_bytes(b'bash unrelated-build')
        with self.assertRaises(AssertionError):
            self.snapshot()
        self.assertFalse(self.output.exists())

    def test_pid_and_relative_path_contracts_refuse(self) -> None:
        for pid,relative in [(1,self.relative),(123,Path('tmp/migraphx-source-stack/../migraphx-source-stack/backend/build'))]:
            with self.assertRaises(AssertionError):
                self.snapshot(pid=pid,relative=relative)
        other = Path('tmp/other-work/build')
        self.write_inputs(self.process / 'root' / other)
        with self.assertRaises(AssertionError):
            self.snapshot(relative=other)
        self.assertFalse(self.output.exists())

    def test_existing_output_is_never_overwritten(self) -> None:
        self.output.mkdir()
        sentinel = self.output / 'CMakeCache.txt'
        sentinel.write_bytes(b'preserve existing bytes')
        with self.assertRaises(FileExistsError):
            self.snapshot()
        self.assertEqual(sentinel.read_bytes(),b'preserve existing bytes')

    def test_build_symlink_and_overlapping_output_refuse(self) -> None:
        alias = self.source.with_name('alias')
        alias.symlink_to(self.source,target_is_directory=True)
        with self.assertRaises(AssertionError):
            self.snapshot(relative=self.relative.with_name('alias'))
        with self.assertRaises(AssertionError):
            self.snapshot(output=self.source / 'new-snapshot')
        self.assertFalse((self.source / 'new-snapshot').exists())

    def test_nested_file_symlink_refuses(self) -> None:
        folder = self.source / 'CMakeFiles'
        moved = self.work / 'moved-files'
        folder.rename(moved)
        folder.symlink_to(moved,target_is_directory=True)
        with self.assertRaises(AssertionError):
            self.snapshot()
        self.assertFalse(self.output.exists())

    def test_missing_empty_and_oversized_sets_refuse_before_allocation(self) -> None:
        path = self.source / 'CMakeCache.txt'
        for value in [b'',b'x' * 9]:
            path.write_bytes(value)
            with mock.patch.dict(SNAPSHOT['snapshot'].__globals__,{'MAX_FILE':8}), self.assertRaises(AssertionError):
                self.snapshot()
            self.assertFalse(self.output.exists())
        path.unlink()
        with self.assertRaises(FileNotFoundError):
            self.snapshot()
        self.write_inputs(self.source)
        with mock.patch.dict(SNAPSHOT['snapshot'].__globals__,{'MAX_TOTAL':9}), self.assertRaises(AssertionError):
            self.snapshot()
        self.assertFalse(self.output.exists())

    def test_source_and_destination_mutations_cannot_create_receipt(self) -> None:
        original_copy = shutil.copy2
        for changed in ['source','destination']:
            def copy(source: Path, target: Path, *, selected: str = changed) -> object:
                result = original_copy(source,target)
                if source.name == 'CMakeCache.txt':
                    (source if selected == 'source' else target).write_bytes(b'changed')
                return result
            with mock.patch.object(shutil,'copy2',side_effect=copy), self.assertRaises(AssertionError):
                self.snapshot()
            self.assertFalse((self.output / 'observation.json').exists())
            self.output.rename(self.work / changed)
            self.write_inputs(self.source)

    def test_changed_process_start_cannot_create_receipt(self) -> None:
        with self.assertRaises(AssertionError):
            self.snapshot(ticks=('17','18'))
        self.assertFalse((self.output / 'observation.json').exists())


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0],*sys.argv[1:]])
