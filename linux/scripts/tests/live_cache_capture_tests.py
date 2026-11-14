#!/usr/bin/env python3
"""Exercise real file retention with synthetic proc files and command doubles; no actual build, cache attribution or hardware acceptance."""

from __future__ import annotations

import io
import json
import runpy
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from typing import TYPE_CHECKING
from unittest import mock

if TYPE_CHECKING:
    from typing import Any

ROOT = Path(__file__).resolve().parents[3]
TOOLS = ROOT / 'linux/scripts/local-proof'
sys.path.insert(0,str(TOOLS))
READER = runpy.run_path(str(TOOLS / 'capture-live-sccache-log.py'))
PROFILE = runpy.run_path(str(TOOLS / 'cache_capture_profile.py'))


class CaptureTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix='cache-reader-')
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        self.process = self.work / 'process'
        self.source = self.process / 'root/tmp/sccache.log'
        self.source.parent.mkdir(parents=True)
        self.source.write_bytes(b'original\n')
        self.output = self.work / 'capture'
        self.write_process()

    def write_process(self, phase: str = 'migraphx', ticks: str = '17') -> None:
        (self.process / 'stat').write_text('123 (synthetic process) ' + ' '.join(['S',*['0'] * 18,ticks]))
        (self.process / 'cmdline').write_bytes((PROFILE['PHASE_MARKERS'][phase] + ' --synthetic').encode())

    def capture(self, *, pid: int = 123, phase: str = 'migraphx', timeout: int = 1) -> dict[str, Any]:
        return READER['capture_log'](pid,phase,self.output,timeout,self.process)

    def test_every_reviewed_phase_and_exact_unit_pair(self) -> None:
        for phase in ['gcc','llvm','rust','python','migraphx']:
            owner = 'gpu' if phase == 'migraphx' else 'compiler'
            unit = f'webgpu-{owner}1-{phase}-error-capture-99999999-1.service'
            PROFILE['validate_capture_unit'](unit,phase)
            with self.assertRaises(AssertionError):
                PROFILE['validate_capture_unit'](unit,'llvm' if phase == 'migraphx' else 'migraphx')
            self.write_process(phase)
            with mock.patch.object(time,'monotonic',side_effect=[0,2]):
                record = self.capture(phase=phase)
            self.assertEqual(record['phase'],phase)
            self.assertEqual(record['status'],'captured-partial-observation-timeout')
            self.assertFalse(record['producer_changed'])
            self.output.rename(self.work / phase)
        for unit,phase in [('webgpu-compiler1-unknown-error-capture-99999999-1.service','unknown'),('wrong.service','migraphx')]:
            with self.assertRaises(AssertionError):
                PROFILE['validate_capture_unit'](unit,phase)

    def test_existing_descriptor_survives_process_tree_teardown(self) -> None:
        def teardown(_seconds: int) -> None:
            gone = self.work / 'gone'
            self.process.rename(gone)
            with (gone / 'root/tmp/sccache.log').open('ab') as stream:
                stream.write(b'late tail\n')
        with mock.patch.object(time,'sleep',side_effect=teardown):
            record = self.capture()
        self.assertEqual(record['status'],'captured-after-phase-process-exit')
        self.assertEqual((self.output / 'sccache-error.log').read_bytes(),b'original\nlate tail\n')
        self.assertEqual(record['size'],record['final_inode_size'])
        self.assertEqual((self.output / 'sccache-error.log').stat().st_mode & 0o777,0o600)
        self.assertEqual(json.loads((self.output / 'capture.json').read_text()),record)

    def test_phase_pid_and_lifetime_refusals_precede_output(self) -> None:
        self.write_process('llvm')
        with self.assertRaises(AssertionError):
            self.capture()
        self.assertFalse(self.output.exists())
        self.write_process()
        cases: list[dict[str, Any]] = [{'pid':1},{'timeout':0},{'timeout':21601}]
        for values in cases:
            with self.assertRaises(AssertionError):
                self.capture(**values)
        self.assertFalse(self.output.exists())

    def test_missing_linked_and_oversized_logs_refuse_before_allocation(self) -> None:
        self.source.unlink()
        with self.assertRaises(FileNotFoundError):
            self.capture()
        target = self.work / 'linked log'
        target.write_bytes(b'separate')
        self.source.symlink_to(target)
        with self.assertRaises(AssertionError):
            self.capture()
        self.source.unlink()
        self.source.write_bytes(b'')
        with self.source.open('r+b') as stream:
            stream.truncate(65)
        with mock.patch.dict(READER['capture_log'].__globals__,{'MAX_LOG':64}), self.assertRaises(AssertionError):
            self.capture()
        self.assertFalse(self.output.exists())

    def test_replaced_live_inode_cannot_produce_a_receipt(self) -> None:
        def replace(_seconds: int) -> None:
            self.source.unlink()
            self.source.write_bytes(b'replacement')
        with mock.patch.object(time,'sleep',side_effect=replace), self.assertRaises(AssertionError):
            self.capture()
        self.assertFalse((self.output / 'capture.json').exists())

    def test_growth_past_bound_and_reused_output_refuse(self) -> None:
        def grow(_seconds: int) -> None:
            with self.source.open('r+b') as stream:
                stream.truncate(65)
            (self.process / 'stat').unlink()
        with mock.patch.dict(READER['capture_log'].__globals__,{'MAX_LOG':64}), mock.patch.object(time,'sleep',side_effect=grow), self.assertRaises(AssertionError):
            self.capture()
        self.write_process()
        self.source.write_bytes(b'valid')
        with self.assertRaises(FileExistsError):
            self.capture()

    def test_pid_reuse_and_final_size_mismatch_remain_observable(self) -> None:
        with mock.patch.dict(READER['stream_log'].__globals__,{'start_ticks':mock.Mock(return_value='18')}), self.source.open('rb') as handle:
            status = READER['stream_log'](handle,self.process,'17',self.work / 'reuse.log',1)
        self.assertEqual(status,'captured-after-phase-process-exit')
        with mock.patch.dict(READER['capture_log'].__globals__,{'stream_log':mock.Mock(side_effect=lambda _handle,_process,_ticks,destination,_timeout: destination.write_bytes(b'short'))}), self.assertRaises(AssertionError):
            self.capture()

    def replay_fixture(self) -> tuple[list[str], Path]:
        old_output = self.work / 'historical-output'
        unit = 'webgpu-compiler1-llvm-error-capture-99999999-1.service'
        command = ['systemd-run','--user','--no-block','--expand-environment=no','--unit=' + unit]
        for value in ['Type=oneshot','RemainAfterExit=yes','TimeoutStartSec=10860','TimeoutStopSec=60','KillMode=control-group','MemoryMax=256M',
                      'StandardOutput=append:/historical/llvm-error-capture-unit.log','StandardError=append:/historical/llvm-error-capture-unit.log']:
            command += ['-p',value]
        command += ['python3','/historical/capture-live-sccache-log.py','--pid','123','--phase','llvm','--output',str(old_output)]
        template = self.work / 'template.json'
        template.write_text(json.dumps({'unit':unit,'producer_unit':'historical.service','command':command}))
        argv = ['replay','--template',str(template),'--phase','migraphx','--pid','123','--output',str(self.output),
                '--unit','webgpu-gpu1-migraphx-error-capture-99999999-1.service','--producer-unit','webgpu-normal-gpu-amd64-99999999-1.service']
        return argv,self.work / 'migraphx-error-capture-invocation.json'

    def test_replay_uses_current_worker_companion_and_fresh_logs_with_raw_status(self) -> None:
        argv,invocation = self.replay_fixture()
        answers = [subprocess.CompletedProcess([],0,'not-found\n',''),subprocess.CompletedProcess([],0,'ActiveState=activating\nMainPID=456\n',''),
                   subprocess.CompletedProcess([],47,'launch output','launch error')]
        with mock.patch.object(sys,'argv',argv), mock.patch.object(subprocess,'run',side_effect=answers), redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as ended:
            runpy.run_path(str(TOOLS / 'replay-sccache-log-capture.py'),run_name='__main__')
        self.assertEqual(ended.exception.code,47)
        record = json.loads(invocation.read_text())
        self.assertEqual(record['launch_status'],47)
        worker = str(TOOLS / 'capture-live-sccache-log.py')
        self.assertIn(worker,record['command'])
        self.assertEqual(set(record['capture_inputs_sha256']),{worker,str(TOOLS / 'cache_capture_profile.py')})
        for filename, actual in record['capture_inputs_sha256'].items():
            self.assertEqual(actual,READER['hashlib'].sha256(Path(filename).read_bytes()).hexdigest())
        for stream in ['StandardOutput','StandardError']:
            self.assertIn(stream + '=append:' + str(self.work / 'migraphx-error-capture-unit.log'),record['command'])

    def test_replay_refuses_existing_unit_and_dead_producer(self) -> None:
        argv,invocation = self.replay_fixture()
        for answers in [[subprocess.CompletedProcess([],0,'loaded\n','')],
                        [subprocess.CompletedProcess([],0,'not-found\n',''),subprocess.CompletedProcess([],0,'ActiveState=inactive\nMainPID=0\n','')]]:
            with mock.patch.object(sys,'argv',argv), mock.patch.object(subprocess,'run',side_effect=answers), self.assertRaises(AssertionError):
                runpy.run_path(str(TOOLS / 'replay-sccache-log-capture.py'),run_name='__main__')
            self.assertFalse(invocation.exists())


    def test_final_exit_drain_keeps_bytes_written_after_the_first_read(self) -> None:
        calls = 0
        def ticks(_process: Path) -> str:
            nonlocal calls
            calls += 1
            if calls == 1:
                return '17'
            with self.source.open('ab') as stream:
                stream.write(b'final drain')
            raise FileNotFoundError
        with mock.patch.dict(READER['capture_log'].__globals__,{'start_ticks':ticks}):
            record = self.capture()
        self.assertEqual((self.output / 'sccache-error.log').read_bytes(),b'original\nfinal drain')
        self.assertEqual(record['status'],'captured-after-phase-process-exit')

    def sealer_fixture(self, phase: str = 'migraphx') -> tuple[Path, dict[str, Any], str]:
        self.write_process(phase)
        with mock.patch.object(time,'monotonic',side_effect=[0,2]):
            self.capture(phase=phase)
        worker = TOOLS / 'capture-live-sccache-log.py'
        paths = [worker, TOOLS / 'cache_capture_profile.py']
        invocation = self.work / 'invocation.json'
        value = {'unit':f'webgpu-{"gpu" if phase == "migraphx" else "compiler"}1-{phase}-error-capture-99999999-1.service',
                 'command':['python3',str(worker),'--pid','123','--phase',phase,'--output',str(self.output)],
                 'capture_script_sha256':READER['hashlib'].sha256(worker.read_bytes()).hexdigest(),
                 'capture_inputs_sha256':{str(path):READER['hashlib'].sha256(path.read_bytes()).hexdigest() for path in paths}}
        terminal = 'LoadState=loaded\nActiveState=active\nSubState=exited\nMainPID=0\nExecMainStatus=0\nResult=success\nExecMainExitTimestampMonotonic=1\n'
        return invocation,value,terminal

    def test_sealer_checks_exact_worker_closure_and_stops_completed_reader(self) -> None:
        invocation,value,terminal = self.sealer_fixture()
        for inputs in [{}, {str(TOOLS / 'capture-live-sccache-log.py'):value['capture_script_sha256']}, dict(value['capture_inputs_sha256'], unexpected='hash')]:
            invocation.write_text(json.dumps(dict(value,capture_inputs_sha256=inputs)))
            with mock.patch.object(sys,'argv',['seal','--invocation',str(invocation)]), mock.patch.object(subprocess,'run',return_value=subprocess.CompletedProcess([],0,terminal,'')), self.assertRaises(AssertionError):
                runpy.run_path(str(TOOLS / 'seal-sccache-log-capture.py'),run_name='__main__')
            self.assertFalse((self.output / 'unit-proof.json').exists())
        invocation.write_text(json.dumps(value))
        answers = [subprocess.CompletedProcess([],0,terminal,''),subprocess.CompletedProcess([],0,'',''),
                   subprocess.CompletedProcess([],0,'LoadState=not-found\nActiveState=inactive\nMainPID=0\n','')]
        with mock.patch.object(sys,'argv',['seal','--invocation',str(invocation)]), mock.patch.object(subprocess,'run',side_effect=answers), redirect_stdout(io.StringIO()):
            runpy.run_path(str(TOOLS / 'seal-sccache-log-capture.py'),run_name='__main__')
        proof = json.loads((self.output / 'unit-proof-stopped.json').read_text())
        self.assertFalse(proof['complete_phase_process_observed'])
        self.assertFalse(proof['compiler_or_image_pass_claimed'])
        self.assertEqual(proof['stopped']['MainPID'],'0')



    def test_compiler_reader_hash_changes_remain_fatal(self) -> None:
        invocation,value,terminal = self.sealer_fixture('llvm')
        value['capture_inputs_sha256'][str(TOOLS / 'cache_capture_profile.py')] = 'wrong'
        invocation.write_text(json.dumps(value))
        with mock.patch.object(sys,'argv',['seal','--invocation',str(invocation)]), mock.patch.object(subprocess,'run',return_value=subprocess.CompletedProcess([],0,terminal,'')), self.assertRaises(AssertionError):
            runpy.run_path(str(TOOLS / 'seal-sccache-log-capture.py'),run_name='__main__')
        self.assertFalse((self.output / 'unit-proof.json').exists())

    def test_replay_requires_its_bounded_transport(self) -> None:
        argv,invocation = self.replay_fixture()
        template = Path(argv[argv.index('--template') + 1])
        value = json.loads(template.read_text())
        value['command'].remove('MemoryMax=256M')
        template.write_text(json.dumps(value))
        with mock.patch.object(sys,'argv',argv), self.assertRaises(AssertionError):
            runpy.run_path(str(TOOLS / 'replay-sccache-log-capture.py'),run_name='__main__')
        self.assertFalse(invocation.exists())



    def failure_audit(self, output: Path, text: str, *, quality: bool = False) -> dict[str, Any]:
        output.mkdir()
        unit = 'webgpu-cache-reader-source-fixture.service'
        (output / 'invocation.json').write_text(json.dumps({'source':str(ROOT),'unit':unit,'owner_label':'org.kataglyphis.migraphx-source','run_id':'synthetic-run'}))
        (output / 'cleanup.json').write_text(json.dumps({'exit_status':0,'run_id':'synthetic-run'}))
        (output / 'container.cid').write_text('a' * 64)
        (output / 'selected-mutations.json').write_text(json.dumps([{'id':'fixture-a'},{'id':'fixture-b'}]))
        (output / 'mutations.log').write_text(text)
        if quality:
            (output / 'preflight.log').write_text('✗ python lint (ruff)\n')
        before = 'Id=' + unit + '\nLoadState=loaded\nActiveState=failed\nSubState=failed\nMainPID=0\nExecMainStatus=1\nExecMainExitTimestampMonotonic=1\n'
        with mock.patch.object(sys,'argv',['audit','--directory',str(output)]), mock.patch.object(sys,'path',sys.path.copy()), \
                mock.patch.object(subprocess,'check_output',side_effect=[before,'MainPID=0\nActiveState=inactive\n']), \
                mock.patch.object(subprocess,'run',return_value=subprocess.CompletedProcess([],0,'','')), redirect_stdout(io.StringIO()):
            runpy.run_path(str(TOOLS / 'audit-failed-source-check.py'),run_name='__main__')
        return json.loads((output / 'failure-proof-stopped.json').read_text())

    def test_failure_audit_retains_survivors_and_quality_failure_separately(self) -> None:
        text = '[1/2]   bites   fixture-a reason\n[2/2] FAIL: fixture-b SURVIVED -- fixture\nFAILED: 1 of 2 entr(ies)\n'
        proof = self.failure_audit(self.work / 'survived',text)
        self.assertEqual(proof['actual_mutations_passed'],1)
        self.assertEqual(proof['actual_mutations_survived'],['fixture-b'])
        self.assertFalse(proof['source_accepted'])
        self.assertTrue(proof['owned_container_absent'])
        success = '[1/2]   bites   fixture-a reason\n[2/2]   bites   fixture-b reason\ncoverage: proved 2 of 2: the whole manifest\nOK: every recorded mutation is caught by its tests\n'
        proof = self.failure_audit(self.work / 'quality',success,quality=True)
        self.assertEqual(proof['actual_mutations_passed'],2)
        self.assertEqual(proof['actual_mutations_survived'],[])
        for index, candidate in enumerate([text.replace('bites   fixture-a','bites   unknown'),text.replace('FAILED: 1','FAILED: 2'),text + 'OK: every recorded mutation is caught\n']):
            output = self.work / ('invalid-' + str(index))
            with self.assertRaises(AssertionError):
                self.failure_audit(output,candidate)
            self.assertFalse((output / 'failure-proof.json').exists())


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0],*sys.argv[1:]])
