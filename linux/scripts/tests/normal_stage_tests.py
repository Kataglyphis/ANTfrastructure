#!/usr/bin/env python3
"""Exercise ordinary stage refusal gates with synthetic OCI and command doubles; no real build, source authentication or GPU acceptance."""

from __future__ import annotations

import importlib
import io
import json
import runpy
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from typing import TYPE_CHECKING
from unittest import mock

from native_oci_seed_tests import OCI, layout

if TYPE_CHECKING:
    from typing import Any

ROOT = Path(__file__).resolve().parents[3]
TOOLS = ROOT / 'linux/scripts/local-proof'
sys.path.insert(0, str(TOOLS))
STAGE = importlib.import_module('normal_stage_launch')
sha = OCI['sha']

GPU = runpy.run_path(str(TOOLS / 'launch-normal-gpu.py'))


class StageTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix='normal-stage-')
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        self.unit = 'webgpu-normal-gpu-amd64-99999999-1.service'
        self.output = self.work / 'output'
        self.image = 'ant-local/webgpu-fixture:cross-toolchain-rocm-amd64'
        tag = self.work / 'linux/scripts/01-core/tag-naming.sh'
        tag.parent.mkdir(parents=True)
        tag.symlink_to(ROOT / 'linux/scripts/01-core/tag-naming.sh')

    def source_fixture(self) -> tuple[Path, Path, dict[str, Any]]:
        source = self.work / 'source'
        (source / 'docs/scripts').mkdir(parents=True)
        (source / 'docs/scripts/mutations.json').write_text(json.dumps([{'id':'synthetic-1'}, {'id':'synthetic-2'}]))
        proof = {'status':'passed-complete-Linux-source-preflight-only', 'source_revision':'synthetic-fixture',
                 'actual_full_registry_mutations':2, 'actual_preflight_group_count':42, 'all_default_preflight_groups':list(range(42)),
                 'command_exit_status':0, 'cleanup_exit_status':0, 'independent_engine_query_exit_status':0,
                 'unit_stopped_after_seal':True, 'owned_container_absent':True, 'script_suites':1, 'script_assertions':2}
        path = self.work / 'full.json'
        path.write_text(json.dumps(proof))
        return source, path, proof

    def test_full_source_refusals_and_positive(self) -> None:
        source, path, proof = self.source_fixture()
        with mock.patch.object(STAGE, 'checked_run', side_effect=[subprocess.CompletedProcess([],0,'synthetic-fixture\n',''), subprocess.CompletedProcess([],0,'','')]):
            self.assertEqual(STAGE.full_source(source,path,'synthetic-fixture'),proof)
        for field,value in [('status','pending'), ('source_revision','different'), ('actual_full_registry_mutations',1),
                            ('actual_preflight_group_count',41), ('all_default_preflight_groups',[]), ('command_exit_status',47),
                            ('cleanup_exit_status',47), ('independent_engine_query_exit_status',47), ('unit_stopped_after_seal',False),
                            ('owned_container_absent',False), ('script_suites',0), ('script_assertions',0)]:
            with self.subTest(field=field), mock.patch.object(STAGE,'checked_run',side_effect=[subprocess.CompletedProcess([],0,'synthetic-fixture\n',''),subprocess.CompletedProcess([],0,'','')]):
                path.write_text(json.dumps(dict(proof, **{field:value})))
                with self.assertRaises(AssertionError):
                    STAGE.full_source(source,path,'synthetic-fixture')
        path.write_text(json.dumps(proof))
        for head,dirty in [('wrong',''), ('synthetic-fixture',' M file')]:
            with mock.patch.object(STAGE,'checked_run',side_effect=[subprocess.CompletedProcess([],0,head,''),subprocess.CompletedProcess([],0,dirty,'')]), self.assertRaises(AssertionError):
                STAGE.full_source(source,path,'synthetic-fixture')

    def host_command(self, command: list[str]) -> subprocess.CompletedProcess[str]:
        key = 'manager' if command[-1] == 'show-environment' else 'unit'
        if Path(command[0]).name == 'nerdctl':
            key = command[1]
        if command[0] == 'ps':
            key = 'processes'
        return subprocess.CompletedProcess(command,0,self.host_values.get(key,''),'')

    def test_host_collisions_flags_and_busy_work_refuse(self) -> None:
        self.host_values = {'unit':'not-found\n'}
        with mock.patch.object(Path,'home',return_value=self.work), mock.patch.object(STAGE,'checked_run',side_effect=self.host_command):
            self.assertEqual(STAGE.host_admission(self.unit,self.output,self.image),self.work / '.cache' / self.unit.removesuffix('.service'))
            for key,value in [('manager','CROSS_VARIANT=rocm\n'), ('manager','ENABLE_AMD=true\n'), ('manager','DRY_RUN=1\n'),
                              ('unit','loaded\n'), ('images',json.dumps({'Repository':'ant-local/webgpu-fixture','Tag':'cross-toolchain-rocm-amd64'})),
                              ('ps','running-container\n'), ('processes','123 nerdctl build .\n'), ('processes','234 bash build-cross-chain.sh\n')]:
                with self.subTest(key=key,value=value):
                    self.host_values = {'unit':'not-found\n',key:value}
                    with self.assertRaises(AssertionError):
                        STAGE.host_admission(self.unit,self.output,self.image)
            self.host_values = {'unit':'not-found\n'}
            for collision in [self.output,self.work / '.cache' / self.unit.removesuffix('.service'),self.work / '.git']:
                collision.mkdir(parents=True)
                with self.assertRaises(AssertionError):
                    STAGE.host_admission(self.unit,self.output,self.image)
                collision.rmdir()

    def launch(self, *, stage: str = 'gpu', variant: str = 'rocm', available: int = 200 * 1024**3,
               required: int = 193273528320, status: int = 0, repo: str = 'ant-local/webgpu-fixture', arch: str = 'amd64', unit: str = '') -> tuple[int, dict[str, Any]]:
        disk = mock.Mock(return_value={'available_bytes':available})
        original_run = subprocess.run
        transport = mock.Mock(side_effect=lambda command, **options: subprocess.CompletedProcess(command,status,'transport-out','transport-err')
                              if command[0] == 'systemd-run' else original_run(command,**options))
        with mock.patch.object(STAGE,'host_admission',return_value=self.work / 'temporary') as host, \
                mock.patch.object(runpy,'run_path',return_value={'require_build_disk':disk}), \
                mock.patch.object(subprocess,'run',transport), mock.patch.object(sys,'path',sys.path.copy()), redirect_stdout(io.StringIO()):
            result = STAGE.launch_stage(self.work,self.output,unit or self.unit.replace('-gpu-', '-' + stage + '-'),repo,stage,arch,
                                       self.work / 'parent context','ant-local/webgpu-parent@sha256:' + 'a' * 64,required,{'parent_manifest':'sha256:' + 'a' * 64},variant)
        expected = {'gpu':self.image, 'sdk':'ant-local/webgpu-fixture:cross-sdk-amd64', 'media':'ant-local/webgpu-fixture:cross-media-rocm-amd64', 'android':'ant-local/webgpu-fixture:cross-android-rocm-amd64'}
        host.assert_called_once_with(self.unit.replace('-gpu-', '-' + stage + '-'),self.output,expected[stage])
        disk.assert_called_once_with(self.output.parent)
        return result,json.loads((self.output / 'invocation.json').read_text())

    def test_gpu_command_and_raw_launch_status(self) -> None:
        status, record = self.launch(status=47)
        self.assertEqual(status,47)
        self.assertEqual(record['launch_status'],47)
        command = record['command']
        self.assertEqual(command[-10:],['/bin/bash',str(self.work / 'linux/scripts/build-cross-stage.sh'),'--stage','gpu','--arch','amd64','--image-repo','ant-local/webgpu-fixture','--log-dir',str(self.output / 'logs')])
        for value in ['--expand-environment=no','TimeoutStartSec=21600','TimeoutStopSec=300','KillMode=control-group','RemainAfterExit=yes',
                      'LC_ALL=C','CROSS_VARIANT=rocm','CROSS_GPU_BASE_IMAGE=ant-local/webgpu-parent@sha256:' + 'a' * 64,
                      'CROSS_GPU_BASE_CONTEXT=' + str(self.work / 'parent context')]:
            self.assertIn(value,command)
        self.assertEqual(record['image'],self.image)
        self.assertFalse(record['publication'])
        self.assertNotIn('--push',command)
        self.assertNotIn('--gates-only',command)

    def test_sdk_command_keeps_qualified_parent_transport(self) -> None:
        status, record = self.launch(stage='sdk',variant='')
        self.assertEqual(status,0)
        self.assertEqual(record['image'],'ant-local/webgpu-fixture:cross-sdk-amd64')
        self.assertIn('CROSS_SDK_BASE_CONTEXT=' + str(self.work / 'parent context'),record['command'])
        self.assertFalse(any(value.startswith('CROSS_VARIANT=') for value in record['command']))

    def test_media_requires_both_wasm_modes_and_normal_parent(self) -> None:
        status, record = self.launch(stage='media')
        self.assertEqual(status,0)
        command = record['command']
        self.assertEqual(record['image'],'ant-local/webgpu-fixture:cross-media-rocm-amd64')
        for value in ['ORT_WEB_REQUIRED=1','ORT_WASM_WEBGPU_FLAVORS=true','CROSS_VARIANT=rocm',
                      'CROSS_MEDIA_BASE_IMAGE=ant-local/webgpu-parent@sha256:' + 'a' * 64,
                      'CROSS_MEDIA_BASE_CONTEXT=' + str(self.work / 'parent context')]:
            self.assertEqual(command.count(value),1)
        self.assertEqual(command[-8:-6],['--stage','media'])
        self.assertNotIn('--push',command)

    def test_android_uses_its_exact_native_media_parent(self) -> None:
        status, record = self.launch(stage='android',status=47)
        self.assertEqual(status,47)
        self.assertEqual(record['image'],'ant-local/webgpu-fixture:cross-android-rocm-amd64')
        command = record['command']
        for value in ('CROSS_ANDROID_BASE_CONTEXT=' + str(self.work / 'parent context'),
                      'CROSS_ANDROID_BASE_IMAGE=ant-local/webgpu-parent@sha256:' + 'a' * 64, 'CROSS_VARIANT=rocm'):
            self.assertEqual(command.count(value),1)
        self.assertEqual(command[-8:-6],['--stage','android'])
        self.assertNotIn('ORT_WEB_REQUIRED=1',command)
        self.assertFalse(record['publication'])

    def test_disk_floor_and_profiles_refuse_before_allocation(self) -> None:
        cases: list[dict[str, Any]] = [{'available':193273528319}, {'required':193273528319}, {'repo':'public/fixture'}, {'stage':'media','variant':''}, {'stage':'media','arch':'arm64'}, {'variant':'unreviewed'}, {'arch':'arm64'}, {'unit':'wrong.service'}, {'variant':''}]
        for values in cases:
            with self.subTest(values=values), self.assertRaises(AssertionError):
                self.launch(**values)
            self.assertFalse(self.output.exists())
            self.assertFalse((self.work / 'temporary').exists())

    def parent_fixture(self) -> tuple[dict[str, Any], Path, Path, dict[str, Any]]:
        compiler = self.work / 'compiler context'
        native = layout(compiler,[f'compiler-{index}'.encode() for index in range(26)])
        context = self.work / 'SDK context'
        sdk = layout(context,[f'compiler-{index}'.encode() for index in range(26)] + [b'SDK layer'])
        parent = {'status':'passed-qualified-native-compiler-OCI-and-base-ancestry','all_native_blob_sizes_and_sha256_verified':True,
                  'context':str(compiler),'manifest':native[0],'config':native[1]['config']['digest'],'index_sha256':sha(compiler / 'index.json'),
                  'layers':26,'stopped':{'ActiveState':'inactive','MainPID':'0'}}
        parent_path = self.work / 'compiler.json'
        parent_path.write_text(json.dumps(parent))
        self.subject = {'kind':'sdk-amd64','image':'ant-local/webgpu-fixture:cross-sdk-amd64','compiler_parent_proof':str(parent_path)}
        qualification = self.work / 'qualification.json'
        self.qualified = {'actual_image_manifest':sdk[0],'image_config':sdk[1]['config']['digest']}
        qualification.write_text(json.dumps(self.qualified))
        proof: dict[str, Any] = dict(parent,status='passed-qualified-native-SDK-OCI-and-compiler-ancestry', SDK_built=True, context=str(context),
                     source_revision='synthetic-fixture',subject=self.subject,parent_layer_reuse_verified=True,
                     export_transport={'producer_status':0,'extractor_status':0},matched_compiler_layers_and_diffIDs=26,
                     manifest=sdk[0],config=sdk[1]['config']['digest'],layers=27,index_sha256=sha(context / 'index.json'),
                     qualification_proof=str(qualification),qualification_sha256=sha(qualification))
        proof_path = self.work / 'SDK proof.json'
        proof_path.write_text(json.dumps(proof))
        self.actual = [{'Id':proof['config'],'RepoDigests':['ant-local/webgpu-fixture@' + proof['manifest']]}]
        return {'source_revision':'synthetic-fixture'},self.work / 'SDK invocation.json',proof_path,proof

    def check_parent(self, plan: dict[str, Any], invocation: Path, proof_path: Path, *, arch: str = 'amd64') -> tuple[dict[str, Any], Path]:
        qualify = mock.Mock(return_value=self.qualified)
        with mock.patch.dict(GPU['sdk_parent'].__globals__,{'load_subject':mock.Mock(return_value=self.subject),
                             'checked_run':mock.Mock(return_value=subprocess.CompletedProcess([],0,json.dumps(self.actual),''))}), \
                mock.patch.object(runpy,'run_path',return_value={'qualification':qualify}):
            result = GPU['sdk_parent'](plan,invocation,proof_path,arch=arch)
        qualify.assert_called_once_with(Path(result[0]['qualification_proof']),plan,invocation)
        return result

    def test_sdk_parent_real_blobs_and_refusals(self) -> None:
        plan,invocation,path,proof = self.parent_fixture()
        self.assertEqual(self.check_parent(plan,invocation,path)[0],proof)
        with self.assertRaisesRegex(AssertionError, 'SDK parent target differs'):
            self.check_parent(plan,invocation,path,arch='arm64')
        for field,value in [('status','pending'), ('SDK_built',False), ('source_revision','different'), ('subject',{}),
                            ('parent_layer_reuse_verified',False), ('export_transport',{'producer_status':47,'extractor_status':0}),
                            ('matched_compiler_layers_and_diffIDs',25), ('qualification_sha256','wrong')]:
            with self.subTest(field=field):
                path.write_text(json.dumps(dict(proof,**{field:value})))
                with self.assertRaises(AssertionError):
                    self.check_parent(plan,invocation,path)
        path.write_text(json.dumps(proof))
        for index,config in [('wrong',proof['config']), (proof['manifest'],'wrong')]:
            self.actual = [{'Id':config,'RepoDigests':['fixture@' + index]}]
            with self.assertRaises(AssertionError):
                self.check_parent(plan,invocation,path)

    def test_changed_native_layer_and_qualification_identity_refuse(self) -> None:
        plan,invocation,path,proof = self.parent_fixture()
        self.qualified['image_config'] = 'wrong'
        with self.assertRaises(AssertionError):
            self.check_parent(plan,invocation,path)
        self.qualified['image_config'] = proof['config']
        layer = next((Path(proof['context']) / 'blobs/sha256').iterdir())
        layer.write_bytes(b'x' * layer.stat().st_size)
        with self.assertRaises((AssertionError,json.JSONDecodeError)):
            self.check_parent(plan,invocation,path)


    def test_compiler_parent_profile_and_real_ancestry_are_required(self) -> None:
        plan,invocation,path,proof = self.parent_fixture()
        parent_path = Path(self.subject['compiler_parent_proof'])
        parent = json.loads(parent_path.read_text())
        parent_path.write_text(json.dumps(dict(parent,status='passed-qualified-native-SDK-OCI-and-compiler-ancestry')))
        with self.assertRaises(AssertionError):
            self.check_parent(plan,invocation,path)
        parent_path.write_text(json.dumps(parent))
        foreign = self.work / 'unrelated SDK context'
        native = layout(foreign,[b'unrelated-layer'] * 27)
        proof.update(context=str(foreign),manifest=native[0],config=native[1]['config']['digest'],index_sha256=sha(foreign / 'index.json'))
        path.write_text(json.dumps(proof))
        self.qualified = {'actual_image_manifest':proof['manifest'],'image_config':proof['config']}
        self.actual = [{'Id':proof['config'],'RepoDigests':['fixture@' + proof['manifest']]}]
        with self.assertRaises(AssertionError):
            self.check_parent(plan,invocation,path)

    def test_cli_binds_exact_sdk_source_before_launch(self) -> None:
        plan,invocation,path,parent = self.parent_fixture()
        plan.update(source=str(self.work / 'source'),full_source_preflight_proof=str(self.work / 'full.json'),required_bytes=193273528320)
        Path(plan['full_source_preflight_proof']).write_text('synthetic full proof')
        plan_path = self.work / 'plan.json'
        plan_path.write_text(json.dumps(plan))
        invocation.write_text(json.dumps({'source':plan['source'],'source_revision':plan['source_revision'],'image':'ant-local/webgpu-fixture:cross-sdk-amd64'}))
        argv = ['launch-normal-gpu.py','--compiler-plan',str(plan_path),'--sdk-invocation',str(invocation),'--parent-proof',str(path),
                '--output',str(self.output),'--unit',self.unit,'--image-repo','ant-local/webgpu-fixture']
        full,launch = mock.Mock(),mock.Mock(return_value=0)
        with mock.patch.dict(GPU['main'].__globals__,{'full_source':full,'sdk_parent':mock.Mock(return_value=(parent,Path(parent['context']))),'launch_stage':launch}), mock.patch.object(sys,'argv',argv):
            self.assertEqual(GPU['main'](),0)
            full.assert_called_once_with(Path(plan['source']),Path(plan['full_source_preflight_proof']),plan['source_revision'])
            self.assertEqual(launch.call_args.args[4:6],('gpu','amd64'))
            self.assertEqual(launch.call_args.kwargs,{'variant':'rocm'})
            self.assertFalse(launch.call_args.args[9]['GPU_or_final_image_acceptance'])
            self.assertEqual(launch.call_args.args[7],'ant-local/webgpu-fixture@' + parent['manifest'])
            repair = self.work / 'reviewed GPU source'
            repair_proof = self.work / 'reviewed full proof.json'
            repair_proof.write_text('independent repaired source proof')
            review = {'profile':'hip-object-output'}
            selected = mock.Mock(return_value=(repair,'f' * 40,repair_proof,review))
            repair_argv = [*argv,'--gpu-source',str(repair),'--gpu-source-proof',str(repair_proof)]
            with mock.patch.dict(GPU['main'].__globals__,{'select_gpu_source':selected}), mock.patch.object(sys,'argv',repair_argv):
                launch.reset_mock()
                self.assertEqual(GPU['main'](),0)
                selected.assert_called_once_with(plan,repair,repair_proof)
                self.assertEqual(launch.call_args.args[0],repair)
                record = launch.call_args.args[9]
                self.assertEqual(record['source_revision'],'f' * 40)
                self.assertEqual(record['parent_source_revision'],plan['source_revision'])
                self.assertEqual(record['GPU_source_review'],review)
                self.assertEqual((record['source_full_preflight_proof'],record['source_full_preflight_sha256']),(str(repair_proof),sha(repair_proof)))
                self.assertEqual(launch.call_args.args[7],'ant-local/webgpu-fixture@' + parent['manifest'])
                selected.reset_mock()
                invocation.write_text(json.dumps({'source':'wrong','source_revision':plan['source_revision'],'image':'ant-local/webgpu-fixture:cross-sdk-amd64'}))
                with self.assertRaises(AssertionError):
                    GPU['main']()
                selected.assert_not_called()
            launch.reset_mock()
            invocation.write_text(json.dumps({'source':'wrong','source_revision':plan['source_revision'],'image':'ant-local/webgpu-fixture:cross-sdk-amd64'}))
            with self.assertRaises(AssertionError):
                GPU['main']()
            launch.assert_not_called()


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0],*sys.argv[1:]])
