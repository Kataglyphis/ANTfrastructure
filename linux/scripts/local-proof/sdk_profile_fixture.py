"""Provide declared SDK producer doubles; these facts never establish a real build, receipt provenance or acceptance."""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from proof_types import Json


def producer_fixture(arch: str = 'amd64') -> Json:
    plan = {'source':'/fixture-source-only', 'source_revision':'synthetic-fixture', 'full_registry':7, 'unit':'fixture-compiler.service',
            'local_image':'ant-local/webgpu-fixture:cross-compiler-amd64', 'launcher_contract':2}
    parent = {'status':'passed-qualified-native-compiler-OCI-and-base-ancestry', 'SDK_parent_prerequisites_passed':True,
              'all_native_blob_sizes_and_sha256_verified':True, 'source_revision':'synthetic-fixture', 'matched_base_layers_and_diffIDs':12,
              'manifest':'sha256:' + 'a' * 64, 'config':'sha256:' + 'b' * 64, 'index_sha256':'c' * 64, 'layers':26,
              'context':'/fixture-compiler-context-only', 'stopped':{'ActiveState':'inactive','MainPID':'0'}}
    invocation = {'target_arch':arch, 'source':plan['source'], 'source_revision':plan['source_revision'], 'parent_source_revision':plan['source_revision'],
                  'unit':f'webgpu-normal-sdk-{arch}-99999999-1.service', 'launch_status':0, 'publication':False, 'source_full_preflight_passed':True,
                  'producer_source_unchanged':True, 'parent_manifest':parent['manifest'], 'parent_config':parent['config'], 'parent_OCI_index_sha256':parent['index_sha256'],
                  'image':'ant-local/webgpu-fixture:cross-sdk-' + arch, 'output':'/fixture-sdk-output-only'}
    invocation['command'] = ['systemd-run','--user','--expand-environment=no',
                             'CROSS_SDK_BASE_IMAGE=ant-local/webgpu-fixture@' + parent['manifest'], 'CROSS_SDK_BASE_CONTEXT=' + parent['context'],
                             '/bin/bash',plan['source'] + '/linux/scripts/build-cross-stage.sh','--stage','sdk','--arch',arch,
                             '--image-repo','ant-local/webgpu-fixture','--log-dir',invocation['output'] + '/logs']
    full = {'status':'passed-complete-Linux-source-preflight-only', 'source_revision':plan['source_revision'], 'actual_full_registry_mutations':7,
            'command_exit_status':0, 'cleanup_exit_status':0, 'independent_engine_query_exit_status':0, 'owned_container_absent':True, 'unit_stopped_after_seal':True}
    return {'plan':plan,'invocation':invocation,'parent':parent,'full':full}
