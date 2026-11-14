#!/usr/bin/env python3
"""Test synthetic native OCI bytes and real archive transport; no actual SDK, provenance authentication or GPU acceptance."""

from __future__ import annotations

import argparse
import copy
import hashlib
import io
import json
import os
import runpy
import shutil
import subprocess
import sys
import tarfile
import tempfile
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
SEED = runpy.run_path(str(TOOLS / 'native_oci_seed.py'))
OCI = runpy.run_path(str(TOOLS / 'native-oci-handoff.py'))


def blob(context: Path, data: bytes, media_type: str) -> dict[str, Any]:
    digest = hashlib.sha256(data).hexdigest()
    (context / 'blobs/sha256' / digest).write_bytes(data)
    return {'digest':'sha256:' + digest, 'size':len(data), 'mediaType':media_type}


def layout(context: Path, payloads: list[bytes]) -> tuple[str, dict[str, Any], dict[str, Any]]:
    (context / 'blobs/sha256').mkdir(parents=True)
    layers = [blob(context,data,'application/vnd.oci.image.layer.v1.tar+gzip') for data in payloads]
    config = {'os':'linux','architecture':'amd64','rootfs':{'type':'layers','diff_ids':[row['digest'] for row in layers]}}
    config_descriptor = blob(context,json.dumps(config).encode(),'application/vnd.oci.image.config.v1+json')
    manifest = {'schemaVersion':2,'config':config_descriptor,'layers':layers}
    selected = blob(context,json.dumps(manifest).encode(),'application/vnd.oci.image.manifest.v1+json')
    (context / 'index.json').write_text(json.dumps({'schemaVersion':2,'manifests':[selected]}))
    (context / 'oci-layout').write_text(json.dumps({'imageLayoutVersion':'1.0.0'}))
    return selected['digest'],manifest,config


class SeedTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix='oci-seed-')
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.parent = self.work / 'parent context'
        self.child = self.work / 'child context'
        self.payloads = [b'repeated-fixture-layer',b'repeated-fixture-layer',*[f'fixture-layer-{index}'.encode() for index in range(24)]]
        self.parent_layout = layout(self.parent,self.payloads)
        self.proof: dict[str, Any] = {'status':'passed-qualified-native-compiler-OCI-and-base-ancestry',
                            'all_native_blob_sizes_and_sha256_verified':True, 'context':str(self.parent), 'layers':26,
                            'manifest':self.parent_layout[0], 'config':self.parent_layout[1]['config']['digest'],
                            'index_sha256':SEED['sha'](self.parent / 'index.json'), 'stopped':{'ActiveState':'inactive','MainPID':'0'}}
        self.proof_path = self.work / 'parent proof.json'
        self.save_proof()

    def save_proof(self) -> None:
        self.proof_path.write_text(json.dumps(self.proof))

    def seed(self) -> dict:
        self.child.mkdir(exist_ok=True)
        return SEED['seed_layers'](self.proof_path,self.child)

    def archive(self) -> tuple[Path, tuple[str, dict[str, Any], dict[str, Any]]]:
        source = self.work / 'archive context'
        child_layout = layout(source,[*self.payloads,b'fixture-SDK-layer'])
        archive = self.work / 'SDK archive.tar'
        with tarfile.open(archive,'w') as stream:
            stream.add(source,arcname='.')
        return archive,child_layout

    def export(self, *, producer: int = 0, extractor: int = 0, shared: bool = True, conditional: bool = True) -> subprocess.CompletedProcess[str]:
        archive,_ = self.archive()
        binary = self.work / 'bin'
        binary.mkdir()
        for name in ['nerdctl','tar']:
            (binary / name).symlink_to(Path(__file__).with_name('native_oci_transport_fixture.py'))
        environment = dict(os.environ,LC_ALL='C',PYTHONDONTWRITEBYTECODE='1',PATH=str(binary) + os.pathsep + os.environ['PATH'],
                           OCI_FIXTURE_ARCHIVE=str(archive),OCI_REAL_TAR=shutil.which('tar') or '',OCI_FIXTURE_PRODUCER_STATUS=str(producer))
        if extractor:
            environment['OCI_FIXTURE_EXTRACTOR_STATUS'] = str(extractor)
        invocation = 'export_image_to_oci_layout "$2" fixture/sdk "$3" "$4"'
        command = '_BUILD_HELPERS_LOADED=1; source "$1"; ' + ('if ' + invocation + '; then exit 0; else exit "$?"; fi' if conditional else invocation)
        return subprocess.run(['bash','-euo','pipefail','-c',command,'fixture-export',str(ROOT / 'linux/scripts/01-core/context-management.sh'),str(binary / 'nerdctl'),str(self.child),str(self.proof_path) if shared else ''],
                              env=environment,text=True,capture_output=True,timeout=30,check=False)

    def test_shared_archive_keeps_parent_bytes_metadata_and_new_child_index(self) -> None:
        result = self.export()
        self.assertEqual(result.returncode,0,result.stderr)
        parent,record = SEED['verify_seed'](self.proof_path,self.child)
        self.assertEqual(parent,self.parent_layout)
        self.assertEqual(len(record['linked_layers']),25)
        self.assertEqual(record['shared_unique_layer_bytes'],sum(map(len,set(self.payloads))))
        self.assertEqual(OCI['layer_ancestry'](OCI['native_layout'](self.child),parent,26),26)
        self.assertNotEqual((self.child / 'index.json').read_bytes(),(self.parent / 'index.json').read_bytes())
        self.assertNotEqual((self.child / 'oci-layout').stat().st_ino,(self.parent / 'oci-layout').stat().st_ino)
        self.assertEqual(json.loads(Path(str(self.child) + '.transport.json').read_text()),{'producer_status':0,'extractor_status':0})

    def test_parent_proof_refusals(self) -> None:
        for key,value in [('status','pending'),('all_native_blob_sizes_and_sha256_verified',False),('index_sha256','wrong'),
                          ('manifest','sha256:' + '0' * 64),('config','sha256:' + '0' * 64),('layers',25)]:
            with self.subTest(key=key):
                candidate = copy.deepcopy(self.proof)
                candidate[key] = value
                self.proof_path.write_text(json.dumps(candidate))
                with self.assertRaises(AssertionError):
                    self.seed()
                self.assertFalse(SEED['receipt_path'](self.child).exists())
        self.save_proof()

    def test_parent_export_must_be_sealed(self) -> None:
        self.proof['stopped']['MainPID'] = '1'
        self.save_proof()
        with self.assertRaises(AssertionError):
            self.seed()

    def test_qualified_sdk_parent_uses_the_same_verified_byte_protocol(self) -> None:
        self.proof.update(status='passed-qualified-native-SDK-OCI-and-compiler-ancestry',SDK_built=True,matched_compiler_layers_and_diffIDs=26)
        self.save_proof()
        self.assertEqual(len(self.seed()['linked_layers']),25)

    def test_gpu_byte_handoff_is_explicitly_separate_from_qualification(self) -> None:
        self.proof.update(status='passed-native-ROCm-GPU-OCI-and-SDK-ancestry-only',GPU_or_FINAL_acceptance=False)
        self.save_proof()
        self.assertEqual(len(self.seed()['linked_layers']),25)

    def test_identity_refuses_directories_and_symlinks(self) -> None:
        source = self.parent / 'blobs/sha256' / self.parent_layout[1]['layers'][0]['digest'].split(':')[1]
        alias = self.work / 'blob alias'
        alias.symlink_to(source)
        for path in [self.parent,alias]:
            with self.assertRaises(AssertionError):
                SEED['identity'](path)

    def test_proof_and_metadata_symlinks_refuse(self) -> None:
        alias = self.work / 'proof alias'
        alias.symlink_to(self.proof_path)
        original = self.proof_path
        self.proof_path = alias
        with self.assertRaises(AssertionError):
            self.seed()
        self.proof_path = original
        index = self.work / 'outside index.json'
        (self.parent / 'index.json').rename(index)
        (self.parent / 'index.json').symlink_to(index)
        with self.assertRaises(AssertionError):
            self.seed()

    def test_parent_blob_checksum_is_rechecked_before_linking(self) -> None:
        descriptor = self.parent_layout[1]['layers'][2]
        path = self.parent / 'blobs/sha256' / descriptor['digest'].split(':')[1]
        path.write_bytes(b'x' * descriptor['size'])
        with self.assertRaises(AssertionError):
            self.seed()
        self.assertEqual(list(self.child.iterdir()),[])

    def test_descriptor_algorithms_and_symlink_leaves_refuse(self) -> None:
        descriptor = self.parent_layout[1]['layers'][0]
        value = descriptor['digest'].split(':')[1]
        alternative = self.parent / 'blobs/sha512'
        alternative.mkdir()
        (alternative / value).write_bytes(self.payloads[0])
        with self.assertRaises(AssertionError):
            OCI['descriptor_path'](self.parent,dict(descriptor,digest='sha512:' + value))
        source = self.parent / 'blobs/sha256' / value
        target = self.work / 'outside blob'
        source.rename(target)
        source.symlink_to(target)
        with self.assertRaises(AssertionError):
            OCI['descriptor_path'](self.parent,descriptor)

    def test_parent_directory_and_blob_symlinks_refuse(self) -> None:
        alias = self.work / 'parent alias'
        alias.symlink_to(self.parent,target_is_directory=True)
        self.proof['context'] = str(alias)
        self.save_proof()
        with self.assertRaises(AssertionError):
            self.seed()
        self.proof['context'] = str(self.parent)
        self.save_proof()
        blobs = self.work / 'outside blobs'
        (self.parent / 'blobs').rename(blobs)
        (self.parent / 'blobs').symlink_to(blobs,target_is_directory=True)
        with self.assertRaises(AssertionError):
            self.seed()

    def test_fresh_empty_nonoverlapping_context_required(self) -> None:
        self.child.mkdir()
        (self.child / 'stale').write_text('preserve me')
        with self.assertRaises(AssertionError):
            self.seed()
        self.assertEqual((self.child / 'stale').read_text(),'preserve me')
        self.child = self.parent / 'nested child'
        with self.assertRaises(AssertionError):
            self.seed()

    def test_existing_seed_receipt_is_preserved(self) -> None:
        receipt = SEED['receipt_path'](self.child)
        receipt.write_text('preserve this receipt')
        with self.assertRaises(AssertionError):
            self.seed()
        self.assertEqual(receipt.read_text(),'preserve this receipt')

    def test_failed_hardlink_cannot_silently_copy_or_write_receipt(self) -> None:
        with mock.patch.object(os,'link',side_effect=OSError('fixture hardlink failure')), self.assertRaises(OSError):
            self.seed()
        self.assertFalse(SEED['receipt_path'](self.child).exists())

    def test_seed_receipt_refusals(self) -> None:
        self.assertEqual(self.export().returncode,0)
        path = SEED['receipt_path'](self.child)
        original = json.loads(path.read_text())
        for field,value in [('status','pending'),('schema_version',0),('parent_proof','wrong'),('parent_proof_sha256','wrong'),
                            ('parent_context','wrong'),('child_context','wrong'),('parent_manifest','wrong'),('parent_index_sha256','wrong'),
                            ('shared_unique_layer_bytes',0)]:
            with self.subTest(field=field):
                candidate = copy.deepcopy(original)
                candidate[field] = value
                path.write_text(json.dumps(candidate))
                with self.assertRaises(AssertionError):
                    SEED['verify_seed'](self.proof_path,self.child)
        for field,value in [('digest','sha256:' + '0' * 64),('relative_path','../../escape')]:
            candidate = copy.deepcopy(original)
            candidate['linked_layers'][0][field] = value
            path.write_text(json.dumps(candidate))
            with self.assertRaises(AssertionError):
                SEED['verify_seed'](self.proof_path,self.child)

    def test_changed_parent_metadata_refuses_even_with_identical_bytes(self) -> None:
        self.assertEqual(self.export().returncode,0)
        layer = self.parent_layout[1]['layers'][0]
        path = self.parent / 'blobs/sha256' / layer['digest'].split(':')[1]
        path.chmod(0o600)
        with self.assertRaises(AssertionError):
            SEED['verify_seed'](self.proof_path,self.child)

    def test_child_layout_metadata_cannot_share_parent_inode(self) -> None:
        self.assertEqual(self.export().returncode,0)
        (self.child / 'oci-layout').unlink()
        os.link(self.parent / 'oci-layout',self.child / 'oci-layout')
        with self.assertRaises(AssertionError):
            SEED['verify_seed'](self.proof_path,self.child)

    def test_shared_export_refuses_existing_destination(self) -> None:
        self.child.mkdir()
        result = self.export()
        self.assertEqual(result.returncode,2,result.stderr)
        self.assertEqual(list(self.child.iterdir()),[])

    def test_producer_failure_survives_successful_real_extraction(self) -> None:
        result = self.export(producer=47)
        self.assertEqual(result.returncode,47,result.stderr)
        self.assertEqual(json.loads(Path(str(self.child) + '.transport.json').read_text()),{'producer_status':47,'extractor_status':0})

    def test_unconditional_export_retains_failed_producer_receipt(self) -> None:
        result = self.export(producer=47,conditional=False)
        self.assertEqual(result.returncode,47,result.stderr)
        self.assertEqual(json.loads(Path(str(self.child) + '.transport.json').read_text()),{'producer_status':47,'extractor_status':0})

    def test_extractor_failure_and_both_raw_statuses_survive(self) -> None:
        result = self.export(producer=47,extractor=37)
        self.assertEqual(result.returncode,37,result.stderr)
        self.assertEqual(json.loads(Path(str(self.child) + '.transport.json').read_text()),{'producer_status':47,'extractor_status':37})

    def test_default_export_retains_reset_and_raw_producer_failure(self) -> None:
        self.child.mkdir()
        (self.child / 'stale').write_text('old default context')
        result = self.export(producer=47,shared=False)
        self.assertEqual(result.returncode,47,result.stderr)
        self.assertFalse((self.child / 'stale').exists())
        self.assertTrue((self.child / 'index.json').is_file())
        self.assertFalse(SEED['receipt_path'](self.child).exists())

    def test_sdk_export_launch_binds_current_helpers_and_parent(self) -> None:
        args = argparse.Namespace(unit='webgpu-normal-sdk-export-amd64-99999999-1.service', context=self.child,
                                  sdk_invocation=self.work / 'synthetic invocation.json', qualification=self.work / 'synthetic qualification.json')
        args.qualification.write_text('synthetic qualification only')
        plan = {'source':'/synthetic-source-only', 'source_revision':'synthetic-fixture', 'required_bytes':193273528320}
        subject = {'kind':'sdk-amd64','image':'fixture/sdk','compiler_parent_proof':str(self.proof_path)}
        proof = {'actual_image_manifest':'sha256:' + 'a' * 64, 'image_config':'sha256:' + 'b' * 64}
        inspected = [{'Id':proof['image_config'],'RepoDigests':['fixture/sdk@' + proof['actual_image_manifest']]}]
        runner = mock.Mock(return_value=subprocess.CompletedProcess([],0,json.dumps(inspected),''))
        disk = mock.Mock(return_value={'available_bytes':200 * 1024**3,'required_bytes':193273528320})
        with mock.patch.dict(OCI['launch'].__globals__,{'load_subject':mock.Mock(return_value=subject),'state':mock.Mock(return_value={'LoadState':'not-found'}),'run':runner}), \
                mock.patch.object(runpy,'run_path',return_value={'require_build_disk':disk}), \
                mock.patch.object(subprocess,'run',return_value=subprocess.CompletedProcess([],0,'','')), \
                mock.patch.object(sys,'path',sys.path.copy()), redirect_stdout(io.StringIO()):
            self.assertEqual(OCI['launch'](args,plan,proof),0)
        record = json.loads(self.child.with_suffix('.invocation.json').read_text())
        self.assertEqual(record['command'][-1],str(self.proof_path))
        self.assertEqual(record['command'][-5],str(ROOT / 'linux/scripts/01-core/context-management.sh'))
        self.assertTrue(record['parent_layer_reuse_required'])
        self.assertEqual(record['export_input_sha256'],OCI['export_worker_inputs'](plan,True))
        self.assertEqual(len(record['export_input_sha256']),3)

    def seal_fixture(self) -> tuple[argparse.Namespace, dict[str, Any], dict[str, Any], dict[str, Any]]:
        self.assertEqual(self.export().returncode,0)
        child_layout = OCI['native_layout'](self.child)
        qualification = self.work / 'synthetic qualification.json'
        qualification.write_text('synthetic qualification only')
        subject: dict[str, Any] = {'kind':'sdk-amd64','compiler_parent_proof':str(self.proof_path)}
        plan: dict[str, Any] = {'source':'/synthetic-source-only','source_revision':'synthetic-fixture'}
        proof: dict[str, Any] = {'actual_image_manifest':child_layout[0], 'image_config':child_layout[1]['config']['digest']}
        args = argparse.Namespace(unit='webgpu-normal-sdk-export-amd64-99999999-1.service',context=self.child,
                                  qualification=qualification,sdk_invocation=self.work / 'synthetic invocation.json')
        invocation = {'unit':args.unit,'qualification_sha256':SEED['sha'](qualification),'subject':subject,
                      'manifest':child_layout[0],'config':proof['image_config'],'parent_layer_reuse_required':True,
                      'export_input_sha256':OCI['export_worker_inputs'](plan,True)}
        self.child.with_suffix('.invocation.json').write_text(json.dumps(invocation))
        return args,plan,proof,subject

    def run_seal(self, args: argparse.Namespace, plan: dict[str, Any], proof: dict[str, Any], subject: dict[str, Any]) -> int:
        terminal = {'LoadState':'loaded','ActiveState':'active','SubState':'exited','MainPID':'0','ExecMainStatus':'0','Result':'success'}
        stopped = {'ActiveState':'inactive','MainPID':'0'}
        with mock.patch.dict(OCI['seal'].__globals__,{'load_subject':mock.Mock(return_value=subject),
                                                    'state':mock.Mock(side_effect=[terminal,stopped]),
                                                    'run':mock.Mock(return_value=subprocess.CompletedProcess([],0,'',''))}), redirect_stdout(io.StringIO()):
            return OCI['seal'](args,plan,proof)

    def test_sdk_export_seal_requires_worker_reuse_transport_and_link_evidence(self) -> None:
        args,plan,proof,subject = self.seal_fixture()
        invocation_path = self.child.with_suffix('.invocation.json')
        original = json.loads(invocation_path.read_text())
        receipt_path = SEED['receipt_path'](self.child)
        original_seed = json.loads(receipt_path.read_text())
        transport_path = Path(str(self.child) + '.transport.json')
        for case in ['missing-inputs','wrong-input','reuse-flag','failed-transport','bad-link-receipt']:
            with self.subTest(case=case):
                invocation = copy.deepcopy(original)
                seed_receipt = copy.deepcopy(original_seed)
                transport = {'producer_status':0,'extractor_status':0}
                if case == 'missing-inputs':
                    invocation.pop('export_input_sha256')
                elif case == 'wrong-input':
                    invocation['export_input_sha256'][next(iter(invocation['export_input_sha256']))] = 'wrong'
                elif case == 'reuse-flag':
                    invocation['parent_layer_reuse_required'] = False
                elif case == 'failed-transport':
                    transport['producer_status'] = 47
                else:
                    seed_receipt['linked_layers'][0]['relative_path'] = '../../escape'
                invocation_path.write_text(json.dumps(invocation))
                receipt_path.write_text(json.dumps(seed_receipt))
                transport_path.write_text(json.dumps(transport))
                with self.assertRaises(AssertionError):
                    self.run_seal(args,plan,proof,subject)
        invocation_path.write_text(json.dumps(original))
        receipt_path.write_text(json.dumps(original_seed))
        transport_path.write_text(json.dumps({'producer_status':0,'extractor_status':0}))
        self.assertEqual(self.run_seal(args,plan,proof,subject),0)
        result = json.loads(self.child.with_suffix('.proof-stopped.json').read_text())
        self.assertTrue(result['parent_layer_reuse_verified'])
        self.assertEqual(result['matched_compiler_layers_and_diffIDs'],26)


if __name__ == '__main__':
    unittest.main()
