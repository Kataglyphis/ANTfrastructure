#!/usr/bin/env python3
"""Exercise GPU handoff and Media refusal gates with synthetic bytes; no actual build, authenticated receipts or hardware acceptance."""

from __future__ import annotations

import argparse
import copy
import importlib
import io
import json
import runpy
import subprocess
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from typing import TYPE_CHECKING
from unittest import mock

import normal_stage_tests as fixtures
from native_oci_seed_tests import SEED, layout, seeded_copy

if TYPE_CHECKING:
    from typing import Any

PROFILE = importlib.import_module('gpu_handoff_profile')
TOOLS = fixtures.TOOLS
CLI = runpy.run_path(str(TOOLS / 'gpu-oci-handoff.py'))
MEDIA = runpy.run_path(str(TOOLS / 'launch-normal-media.py'))


class HandoffTests(unittest.TestCase):
    def setUp(self) -> None:
        fixture = fixtures.StageTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        self.work, self.unit, self.output, self.image = fixture.work, fixture.unit, fixture.output, fixture.image
        self.plan, self.sdk_invocation, self.parent_path, self.parent = fixture.parent_fixture()
        self.sdk_invocation.write_text('synthetic SDK invocation')
        self.plan.update(source=str(self.work),full_source_preflight_proof=str(self.work / 'full.json'),required_bytes=193273528320)
        self.full = self.work / 'GPU-full.json'
        self.full.write_text('synthetic GPU source proof')
        self.invocation = self.work / 'gpu-invocation.json'
        command = ['systemd-run','--user','--expand-environment=no','-E','CROSS_VARIANT=rocm',
                   '-E','CROSS_GPU_BASE_CONTEXT=' + self.parent['context'],'-E','CROSS_GPU_BASE_IMAGE=ant-local/webgpu-fixture@' + self.parent['manifest'],
                   '/bin/bash',str(self.work / 'linux/scripts/build-cross-stage.sh'),'--stage','gpu','--arch','amd64',
                   '--image-repo','ant-local/webgpu-fixture','--log-dir',str(self.work / 'logs')]
        self.gpu: dict[str, Any] = {'stage':'gpu','variant':'rocm','target_arch':'amd64','unit':self.unit,'launch_status':0,'publication':False,
                    'source_full_preflight_passed':True,'producer_source_unchanged':True,'source':str(self.work),'output':str(self.work),
                    'source_revision':'f' * 40,'parent_source_revision':self.plan['source_revision'],
                    'source_full_preflight_proof':str(self.full),'source_full_preflight_sha256':fixtures.sha(self.full),
                    'GPU_source_review':{'profile':'synthetic fixture'},'SDK_invocation':str(self.sdk_invocation),
                    'SDK_invocation_sha256':fixtures.sha(self.sdk_invocation),'parent_OCI_proof':str(self.parent_path),
                    'parent_OCI_proof_sha256':fixtures.sha(self.parent_path),'parent_manifest':self.parent['manifest'],
                    'parent_config':self.parent['config'],'parent_OCI_index_sha256':self.parent['index_sha256'],
                    'SDK_layers_rehashed':self.parent['layers'],'compiler_layers_rehashed':26,'image':self.image,'command':command}
        self.image_identity = {'manifest':'sha256:' + 'c' * 64,'config':'sha256:' + 'd' * 64,'image':self.image}
        self.success = {'Id':self.unit,'LoadState':'loaded','ActiveState':'active','SubState':'exited','MainPID':'0','ExecMainStatus':'0','Result':'success'}

    def save_gpu(self) -> None:
        self.invocation.write_text(json.dumps(self.gpu))

    def load(self) -> tuple[dict, dict, dict]:
        self.save_gpu()
        selected = mock.Mock(return_value=(self.work,'f' * 40,self.full,{'profile':'synthetic fixture'}))
        with mock.patch.object(PROFILE,'full_source') as full, mock.patch.object(PROFILE,'select_gpu_source',selected), \
                mock.patch.object(runpy,'run_path',return_value={'sdk_parent':mock.Mock(return_value=(self.parent,Path(self.parent['context'])))}):
            result = PROFILE.load_gpu(self.plan_path,self.invocation)
        full.assert_called_once_with(self.work,Path(self.plan['full_source_preflight_proof']),self.plan['source_revision'])
        selected.assert_called_once_with(self.plan,self.work,self.full)
        return result

    @property
    def plan_path(self) -> Path:
        path = self.work / 'plan.json'
        path.write_text(json.dumps(self.plan))
        return path

    def test_gpu_command_and_parent_binding(self) -> None:
        PROFILE.validate_gpu(self.gpu,self.parent)
        changes = [('stage','media'),('variant','nvidia'),('target_arch','arm64'),('unit','wrong.service'),('launch_status',47),
                   ('publication',True),('source_full_preflight_passed',False),('producer_source_unchanged',False),
                   ('parent_manifest','wrong'),('parent_config','wrong'),('parent_OCI_index_sha256','wrong'),
                   ('SDK_layers_rehashed',0),('compiler_layers_rehashed',25),('image','other/candidate')]
        for field,value in changes:
            with self.subTest(field=field), self.assertRaises(AssertionError):
                PROFILE.validate_gpu(dict(self.gpu,**{field:value}),self.parent)
        for before,after in [('CROSS_VARIANT=rocm','CROSS_VARIANT=nvidia'),('CROSS_GPU_BASE_CONTEXT=' + self.parent['context'],'other'),
                             ('CROSS_GPU_BASE_IMAGE=ant-local/webgpu-fixture@' + self.parent['manifest'],'CROSS_GPU_BASE_IMAGE=fixture:tag'),
                             ('--expand-environment=no','--expand-environment=yes'),('--arch','--push')]:
            candidate = copy.deepcopy(self.gpu)
            candidate['command'][candidate['command'].index(before)] = after
            with self.subTest(before=before), self.assertRaises(AssertionError):
                PROFILE.validate_gpu(candidate,self.parent)

    def test_load_checks_original_sdk_and_selected_source(self) -> None:
        self.assertEqual(self.load(),(self.plan,self.gpu,self.parent))
        for field,value in [('output',str(self.work / 'wrong')),('source',str(self.work / 'wrong')),('source_revision','wrong'),('SDK_invocation_sha256','wrong'),('parent_OCI_proof_sha256','wrong'),
                            ('source_full_preflight_sha256','wrong'),('GPU_source_review',{}),('parent_source_revision','wrong')]:
            original = self.gpu[field]
            self.gpu[field] = value
            with self.subTest(field=field), self.assertRaises(AssertionError):
                self.load()
            self.gpu[field] = original

    def test_local_image_tail_and_no_publication_guards_fail_independently(self) -> None:
        candidates = []
        public = copy.deepcopy(self.gpu)
        public['image'] = 'public/fixture:cross-toolchain-rocm-amd64'
        public['command'][public['command'].index('--image-repo') + 1] = 'public/fixture'
        candidates.append(public)
        wrong_stage = copy.deepcopy(self.gpu)
        wrong_stage['command'][wrong_stage['command'].index('--stage') + 1] = 'sdk'
        candidates.append(wrong_stage)
        for option in ('--push','--gates-only'):
            candidate = copy.deepcopy(self.gpu)
            candidate['command'].insert(2,option)
            candidates.append(candidate)
        for candidate in candidates:
            with self.subTest(command=candidate['command']), self.assertRaises(AssertionError):
                PROFILE.validate_gpu(candidate,self.parent)

    def test_output_directory_binding_is_independent_of_command_tail(self) -> None:
        self.gpu['output'] = str(self.work / 'wrong')
        self.gpu['command'][-1] = str(self.work / 'wrong/logs')
        with self.assertRaisesRegex(AssertionError,'GPU output binding differs'):
            self.load()

    def test_terminal_requires_actual_success(self) -> None:
        for field,value in [('Id','wrong'),('LoadState','not-found'),('ActiveState','activating'),('SubState','start'),
                            ('MainPID','123'),('ExecMainStatus','47'),('Result','exit-code')]:
            raw = '\n'.join(key + '=' + item for key,item in dict(self.success,**{field:value}).items())
            with mock.patch.object(PROFILE,'checked_run',return_value=subprocess.CompletedProcess([],0,raw,'')), self.subTest(field=field), self.assertRaises(AssertionError):
                PROFILE.terminal(self.unit)
        raw = '\n'.join(key + '=' + item for key,item in self.success.items())
        with mock.patch.object(PROFILE,'checked_run',return_value=subprocess.CompletedProcess([],0,raw,'')):
            self.assertEqual(PROFILE.terminal(self.unit),self.success)

    def test_actual_engine_manifest_config_and_cardinality(self) -> None:
        image = {'Id':self.image_identity['config'],'RepoDigests':['fixture@' + self.image_identity['manifest']]}
        with mock.patch.object(PROFILE,'terminal') as ended, mock.patch.object(PROFILE,'checked_run',return_value=subprocess.CompletedProcess([],0,json.dumps([image]),'')) as commands:
            self.assertEqual(PROFILE.actual_image(self.gpu),self.image_identity)
            ended.assert_called_once_with(self.unit)
            engine = str(Path.home() / '.local/bin/nerdctl')
            self.assertEqual(commands.call_args_list,[mock.call([engine,'image','inspect',self.gpu['image']]),
                                                     mock.call([engine,'image','inspect',self.image_identity['manifest']])])
        for digests,config in [(['fixture@sha256:bad'],self.image_identity['config']),
                              (['fixture@' + self.image_identity['manifest'],'other@sha256:' + 'e' * 64],self.image_identity['config']),
                              (image['RepoDigests'],'wrong')]:
            image['RepoDigests'] = digests
            image['Id'] = config
            with mock.patch.object(PROFILE,'terminal'), mock.patch.object(PROFILE,'checked_run',return_value=subprocess.CompletedProcess([],0,json.dumps([image]),'')), self.assertRaises(AssertionError):
                PROFILE.actual_image(self.gpu)
        for images in ([],[image,image]):
            with mock.patch.object(PROFILE,'terminal'), mock.patch.object(PROFILE,'checked_run',return_value=subprocess.CompletedProcess([],0,json.dumps(images),'')), self.assertRaises(AssertionError):
                PROFILE.actual_image(self.gpu)

    def test_ambiguous_tag_refuses_even_when_both_local_manifests_resolve(self) -> None:
        tagged = {'Id':self.image_identity['config'],'RepoDigests':
                  ['fixture@' + self.image_identity['manifest'],'other@sha256:' + 'e' * 64]}
        def engine(command: list[str]) -> subprocess.CompletedProcess[str]:
            metadata = tagged if command[-1] == self.gpu['image'] else {
                'Id':self.image_identity['config'],'RepoDigests':['resolved@' + command[-1]]}
            return subprocess.CompletedProcess(command,0,json.dumps([metadata]),'')
        with mock.patch.object(PROFILE,'terminal'), mock.patch.object(PROFILE,'checked_run',side_effect=engine) as queries, \
                self.assertRaisesRegex(AssertionError,'GPU image manifest is ambiguous'):
            PROFILE.actual_image(self.gpu)
        self.assertEqual(queries.call_count,1)

    def test_local_immutable_manifest_lookup_refuses_wrong_identity_or_cardinality(self) -> None:
        tagged = {'Id':self.image_identity['config'],'RepoDigests':['fixture@' + self.image_identity['manifest']]}
        variants = ([],[tagged,tagged],[dict(tagged,Id='sha256:' + 'e' * 64)],
                    [dict(tagged,RepoDigests=['fixture@sha256:' + 'e' * 64])])
        for resolved in variants:
            responses = [subprocess.CompletedProcess([],0,json.dumps([tagged]),''),
                         subprocess.CompletedProcess([],0,json.dumps(resolved),'')]
            with mock.patch.object(PROFILE,'terminal'), mock.patch.object(PROFILE,'checked_run',side_effect=responses), \
                    self.subTest(resolved=resolved), self.assertRaisesRegex(AssertionError,'Local immutable manifest'):
                PROFILE.actual_image(self.gpu)
        responses = [subprocess.CompletedProcess([],0,json.dumps([tagged]),''),RuntimeError('immutable lookup failed')]
        with mock.patch.object(PROFILE,'terminal'), mock.patch.object(PROFILE,'checked_run',side_effect=responses), \
                self.assertRaisesRegex(RuntimeError,'immutable lookup failed'):
            PROFILE.actual_image(self.gpu)

    def native_gpu(self) -> tuple[Path, Path, dict[str, Any]]:
        self.save_gpu()
        context = self.work / 'gpu-context-current'
        native = layout(context,[*[f'compiler-{index}'.encode() for index in range(26)],b'SDK layer',b'GPU layer'])
        proof = {'status':PROFILE.STATUS,'GPU_invocation':str(self.invocation),'GPU_invocation_sha256':fixtures.sha(self.invocation),
                 'source_revision':self.gpu['source_revision'],'parent_OCI_proof_sha256':self.gpu['parent_OCI_proof_sha256'],
                 'export_transport':{'producer_status':0,'extractor_status':0},'parent_layer_reuse_verified':True,
                 'matched_SDK_layers_and_diffIDs':27,'all_native_blob_sizes_and_sha256_verified':True,
                 'context':str(context),'manifest':native[0],'config':native[1]['config']['digest'],
                 'index_sha256':fixtures.sha(context / 'index.json'),'layers':28,'stopped':{'ActiveState':'inactive','MainPID':'0'}}
        path = self.work / 'gpu-proof.json'
        path.write_text(json.dumps(proof))
        self.image_identity.update(manifest=proof['manifest'],config=proof['config'])
        return path,context,proof

    def test_native_layout_matches_real_sdk_bytes_and_receipts(self) -> None:
        path,context,proof = self.native_gpu()
        with mock.patch.object(PROFILE,'actual_image',return_value=self.image_identity):
            self.assertEqual(PROFILE.gpu_layout(path,self.invocation,self.gpu,self.parent),(proof,context))
            for field,value in [('status','pending'),('GPU_invocation',str(self.work / 'other')),('GPU_invocation_sha256','wrong'),
                                ('source_revision','wrong'),('parent_OCI_proof_sha256','wrong'),('parent_layer_reuse_verified',False),
                                ('export_transport',{'producer_status':47,'extractor_status':0}),('matched_SDK_layers_and_diffIDs',26)]:
                path.write_text(json.dumps(dict(proof,**{field:value})))
                with self.subTest(field=field), self.assertRaises(AssertionError):
                    PROFILE.gpu_layout(path,self.invocation,self.gpu,self.parent)
            path.write_text(json.dumps(proof))
            self.image_identity['config'] = 'wrong'
            with self.assertRaises(AssertionError):
                PROFILE.gpu_layout(path,self.invocation,self.gpu,self.parent)

    def test_changed_layer_refuses(self) -> None:
        path,context,_ = self.native_gpu()
        layer = next((context / 'blobs/sha256').iterdir())
        layer.write_bytes(b'x' * layer.stat().st_size)
        with mock.patch.object(PROFILE,'actual_image',return_value=self.image_identity), self.assertRaises((AssertionError,json.JSONDecodeError)):
            PROFILE.gpu_layout(path,self.invocation,self.gpu,self.parent)

    def test_unrelated_valid_gpu_layers_cannot_replace_sdk_ancestry(self) -> None:
        path,_,proof = self.native_gpu()
        other = self.work / 'unrelated valid GPU'
        native = layout(other,[*[f'compiler-{index}'.encode() for index in range(26)],b'foreign SDK',b'GPU layer'])
        proof.update(context=str(other),manifest=native[0],config=native[1]['config']['digest'],index_sha256=fixtures.sha(other / 'index.json'))
        path.write_text(json.dumps(proof))
        self.image_identity.update(manifest=proof['manifest'],config=proof['config'])
        with mock.patch.object(PROFILE,'actual_image',return_value=self.image_identity), self.assertRaisesRegex(AssertionError,'ancestry differs'):
            PROFILE.gpu_layout(path,self.invocation,self.gpu,self.parent)

    def test_media_cli_forwards_real_subject_and_raw_launch_failure(self) -> None:
        self.save_gpu()
        proof,context,parent = self.native_gpu()
        argv = ['launch-normal-media.py','--compiler-plan',str(self.plan_path),'--gpu-invocation',str(self.invocation),
                '--parent-proof',str(proof),'--output',str(self.output),'--unit',self.unit.replace('-gpu-','-media-'),
                '--image-repo','ant-local/webgpu-fixture']
        with mock.patch.object(sys,'argv',argv), mock.patch.dict(MEDIA['main'].__globals__,
                {'load_gpu':mock.Mock(return_value=(self.plan,self.gpu,self.parent)),
                 'gpu_layout':mock.Mock(return_value=(parent,context)),'launch_stage':mock.Mock(return_value=47)}) as scope:
            self.assertEqual(MEDIA['main'](),47)
            call = scope['launch_stage'].call_args.args
        self.assertEqual(call[:1],(self.work,))
        self.assertEqual(call[4:7],('media','amd64',context))
        self.assertEqual(call[7],'ant-local/webgpu-fixture@' + parent['manifest'])
        self.assertEqual(call[8], 300 * 1024**3)
        self.assertEqual(call[9]['GPU_invocation_sha256'],fixtures.sha(self.invocation))

    def export_args(self) -> argparse.Namespace:
        self.save_gpu()
        return argparse.Namespace(context=self.work / 'gpu-context-export',gpu_invocation=self.invocation,
                                  unit='webgpu-normal-gpu-export-amd64-99999999-1.service')

    def launch_export(self, args: argparse.Namespace, *, available: int = 200 * 1024**3, status: int = 0,
                      state: str = 'not-found', kind: str = 'gpu', invocation: dict[str, Any] | None = None) -> int:
        common = dict(CLI['COMMON'],state=mock.Mock(return_value={'LoadState':state}))
        with mock.patch.dict(CLI['launch'].__globals__,{'COMMON':common}), \
                mock.patch.object(runpy,'run_path',return_value={'require_build_disk':mock.Mock(return_value={'available_bytes':available})}), \
                mock.patch.object(subprocess,'run',return_value=subprocess.CompletedProcess([],status,'transport-out','transport-err')), \
                mock.patch.object(sys,'path',sys.path.copy()), redirect_stdout(io.StringIO()):
            return CLI['launch'](args,self.plan,invocation or self.gpu,self.image_identity,kind)

    def test_export_launch_binds_immutable_image_parent_and_raw_transport(self) -> None:
        args = self.export_args()
        self.assertEqual(self.launch_export(args,status=47),47)
        record = json.loads(args.context.with_suffix('.invocation.json').read_text())
        self.assertEqual(record['launch_status'],47)
        self.assertFalse(record['publication'])
        self.assertEqual(record['GPU_invocation_sha256'],fixtures.sha(self.invocation))
        self.assertEqual(record['command'][-3:],[self.image_identity['manifest'],str(args.context),str(self.parent_path)])
        for value in ['TimeoutStartSec=1200','TimeoutStopSec=120','KillMode=control-group','--expand-environment=no']:
            self.assertIn(value,record['command'])

    def test_export_launch_refuses_disk_and_existing_work_before_transport(self) -> None:
        args = self.export_args()
        for available,required in [(193273528319,193273528320),(200 * 1024**3,193273528319)]:
            self.plan['required_bytes'] = required
            with self.assertRaises(AssertionError):
                self.launch_export(args,available=available)
            self.assertFalse(args.context.with_suffix('.invocation.json').exists())
        self.plan['required_bytes'] = 193273528320
        with self.assertRaises(AssertionError):
            self.launch_export(args,state='loaded')
        for collision in (args.context,args.context.with_suffix('.invocation.json')):
            collision.write_text('preserved earlier work')
            with self.assertRaises(AssertionError):
                self.launch_export(args)
            self.assertEqual(collision.read_text(),'preserved earlier work')
            collision.unlink()
        args.context.symlink_to(self.work / 'absent')
        with self.assertRaises(AssertionError):
            self.launch_export(args)
        self.assertTrue(args.context.is_symlink())

    def sealed_export_fixture(self) -> tuple[argparse.Namespace, dict[str, Any]]:
        _,context,_ = self.native_gpu()
        seeded_copy(self.parent_path,context)
        Path(str(context) + '.transport.json').write_text(json.dumps({'producer_status':0,'extractor_status':0}))
        args = self.export_args()
        args.context = context
        record = {'unit':args.unit,'context':str(context),'GPU_invocation':str(self.invocation),
                  'GPU_invocation_sha256':fixtures.sha(self.invocation),'source_revision':self.gpu['source_revision'],
                  'parent_OCI_proof_sha256':self.gpu['parent_OCI_proof_sha256'],'actual_image':self.image_identity,
                  'worker_inputs_sha256':CLI['worker_inputs'](),'launch_status':0}
        context.with_suffix('.invocation.json').write_text(json.dumps(record))
        return args,record

    def seal_export(self, args: argparse.Namespace, *, fail_stop: bool = False, still_running: bool = False,
                    kind: str = 'gpu', invocation: dict[str, Any] | None = None, parent: dict[str, Any] | None = None) -> int:
        stopped = {'ActiveState':'active','MainPID':'1'} if still_running else {'ActiveState':'inactive','MainPID':'0'}
        common = dict(CLI['COMMON'],state=mock.Mock(return_value=stopped))
        stop = mock.Mock(return_value=subprocess.CompletedProcess([],0,'',''))
        if fail_stop:
            stop.side_effect = subprocess.CalledProcessError(47,['systemctl','stop'])
        with mock.patch.dict(CLI['seal'].__globals__,{'COMMON':common,'terminal':mock.Mock(return_value=self.success),'checked_run':stop}), redirect_stdout(io.StringIO()):
            return CLI['seal'](args,invocation or self.gpu,parent or self.parent,self.image_identity,kind)

    def test_export_seal_hashes_real_blobs_and_preserves_parent_links(self) -> None:
        args,_ = self.sealed_export_fixture()
        self.assertEqual(self.seal_export(args),0)
        proof = json.loads(args.context.with_suffix('.proof-stopped.json').read_text())
        self.assertEqual(proof['status'],PROFILE.STATUS)
        self.assertEqual(proof['matched_SDK_layers_and_diffIDs'],27)
        self.assertTrue(proof['all_native_blob_sizes_and_sha256_verified'])
        self.assertTrue(proof['parent_layer_reuse_verified'])
        self.assertFalse(proof['GPU_or_FINAL_acceptance'])
        self.assertFalse(proof['complete_binary_licence_review'])
        self.assertEqual(proof['stopped']['MainPID'],'0')

    def test_export_seal_refuses_changed_inputs_subject_and_transport(self) -> None:
        args,record = self.sealed_export_fixture()
        path = args.context.with_suffix('.invocation.json')
        for field,value in [('unit','wrong'),('context','wrong'),('GPU_invocation','wrong'),('GPU_invocation_sha256','wrong'),
                            ('parent_OCI_proof_sha256','wrong'),('actual_image',{}),('worker_inputs_sha256',{}),('launch_status',47)]:
            path.write_text(json.dumps(dict(record,**{field:value})))
            with self.subTest(field=field), self.assertRaises(AssertionError):
                self.seal_export(args)
            self.assertFalse(args.context.with_suffix('.proof.json').exists())
        path.write_text(json.dumps(record))
        for producer,extractor in [(47,0),(0,47)]:
            Path(str(args.context) + '.transport.json').write_text(json.dumps({'producer_status':producer,'extractor_status':extractor}))
            with self.subTest(producer=producer,extractor=extractor), self.assertRaises(AssertionError):
                self.seal_export(args)
            self.assertFalse(args.context.with_suffix('.proof.json').exists())

    def test_export_seal_never_overwrites_a_proof(self) -> None:
        args,_ = self.sealed_export_fixture()
        previous = args.context.with_suffix('.proof.json')
        previous.write_text('preserved proof')
        with self.assertRaises(AssertionError):
            self.seal_export(args)
        self.assertEqual(previous.read_text(),'preserved proof')
        self.assertFalse(args.context.with_suffix('.proof-stopped.json').exists())

    def test_exported_bytes_must_match_the_current_image_independently(self) -> None:
        args,record = self.sealed_export_fixture()
        for field in ('manifest','config'):
            original = self.image_identity[field]
            self.image_identity[field] = 'sha256:' + 'e' * 64
            args.context.with_suffix('.invocation.json').write_text(json.dumps(record))
            with self.subTest(field=field), self.assertRaisesRegex(AssertionError,'GPU native bytes differ'):
                self.seal_export(args)
            self.assertFalse(args.context.with_suffix('.proof.json').exists())
            self.image_identity[field] = original

    def test_export_seal_requires_unchanged_parent_link_receipt(self) -> None:
        args,_ = self.sealed_export_fixture()
        path = SEED['receipt_path'](args.context)
        receipt = json.loads(path.read_text())
        receipt['shared_unique_layer_bytes'] = 0
        path.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(AssertionError,'shared-byte accounting'):
            self.seal_export(args)
        self.assertFalse(args.context.with_suffix('.proof.json').exists())

    def test_failed_stop_cannot_publish_a_stopped_proof(self) -> None:
        args,_ = self.sealed_export_fixture()
        with self.assertRaises(subprocess.CalledProcessError):
            self.seal_export(args,fail_stop=True)
        self.assertTrue(args.context.with_suffix('.proof.json').is_file())
        self.assertFalse(args.context.with_suffix('.proof-stopped.json').exists())

    def test_remaining_live_unit_cannot_publish_a_stopped_proof(self) -> None:
        args,_ = self.sealed_export_fixture()
        with self.assertRaises(AssertionError):
            self.seal_export(args,still_running=True)
        self.assertFalse(args.context.with_suffix('.proof-stopped.json').exists())

    def test_export_inputs_bind_every_runtime_companion(self) -> None:
        hashes = CLI['worker_inputs']()
        self.assertEqual({Path(path).name for path in hashes},{'context-management.sh','native_oci_seed.py',
                         'native_oci_layout.py','native-oci-handoff.py','normal_stage_launch.py','stage_handoff_profile.py','gpu_handoff_profile.py','gpu-oci-handoff.py'})
        for path,sha256 in hashes.items():
            self.assertEqual(fixtures.sha(Path(path)),sha256)

    def test_gpu_cli_dispatch_keeps_scope_and_raw_status(self) -> None:
        args = self.export_args()
        argv = ['gpu-oci-handoff.py','launch','--compiler-plan',str(self.plan_path),'--gpu-invocation',str(self.invocation),
                '--context',str(args.context),'--unit',args.unit]
        launch = mock.Mock(return_value=47)
        with mock.patch.object(sys,'argv',argv), mock.patch.dict(CLI['main'].__globals__,
                {'load_gpu':mock.Mock(return_value=(self.plan,self.gpu,self.parent)),
                 'actual_image':mock.Mock(return_value=self.image_identity),'launch':launch}):
            self.assertEqual(CLI['main'](),47)
            self.assertEqual(launch.call_args.args[0].context,args.context)
            self.assertEqual(launch.call_args.args[1:],(self.plan,self.gpu,self.image_identity,'gpu'))

    def test_gpu_cli_rejects_wrong_unit_context_and_symlink_parent(self) -> None:
        args = self.export_args()
        alias = self.work / 'alias'
        alias.symlink_to(self.work,target_is_directory=True)
        for unit,context in [('wrong.service',args.context),(args.unit,self.work / 'wrong-context'),
                             (args.unit,alias / 'gpu-context-export')]:
            argv = ['gpu-oci-handoff.py','launch','--compiler-plan',str(self.plan_path),'--gpu-invocation',str(self.invocation),
                    '--context',str(context),'--unit',unit]
            load = mock.Mock()
            with mock.patch.object(sys,'argv',argv), mock.patch.dict(CLI['main'].__globals__,{'load_gpu':load}), self.assertRaises(AssertionError):
                CLI['main']()
            load.assert_not_called()


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0],*sys.argv[1:]])
