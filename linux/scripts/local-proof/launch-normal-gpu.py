#!/usr/bin/env python3
"""Launch the ordinary ROCm amd64 GPU stage from its qualified exact SDK; no rebuilt backend or final acceptance is implied."""

from __future__ import annotations

import argparse
import json
import runpy
from pathlib import Path
from typing import TYPE_CHECKING

from gpu_source_profile import select_gpu_source
from native_oci_layout import layer_ancestry, sha
from native_oci_seed import parent_layout
from normal_stage_launch import full_source, launch_stage
from proof_commands import checked_run
from proof_subject import load_subject

if TYPE_CHECKING:
    from proof_types import Json


def sdk_parent(plan: Json, invocation: Path, proof_path: Path) -> tuple[Json, Path]:
    subject = load_subject(plan, invocation)
    proof, context, native = parent_layout(proof_path)
    assert proof['status'] == 'passed-qualified-native-SDK-OCI-and-compiler-ancestry' and proof['SDK_built'] is True, 'Actual SDK OCI required'
    assert proof['source_revision'] == plan['source_revision'] and proof['subject'] == subject, 'SDK source or subject differs'
    assert proof['parent_layer_reuse_verified'] is True and proof['export_transport'] == {'producer_status':0, 'extractor_status':0}, 'SDK export contains an unverified transport'
    assert proof['matched_compiler_layers_and_diffIDs'] == 26, 'Complete compiler ancestry required'
    parent, _, compiler = parent_layout(Path(subject['compiler_parent_proof']))
    assert parent['status'] == 'passed-qualified-native-compiler-OCI-and-base-ancestry', 'Actual compiler parent required'
    assert layer_ancestry(native, compiler, 26) == 26, 'Compiler descriptors or diffIDs differ'
    module = runpy.run_path(str(Path(__file__).with_name('native-oci-handoff.py')))
    qualification = Path(proof['qualification_proof'])
    assert sha(qualification) == proof['qualification_sha256'], 'SDK qualification bytes differ'
    qualified = module['qualification'](qualification, plan, invocation)
    assert qualified['actual_image_manifest'] == proof['manifest'] and qualified['image_config'] == proof['config'], 'SDK qualification identity differs'
    actual = json.loads(checked_run([str(Path.home() / '.local/bin/nerdctl'), 'image', 'inspect', subject['image']]).stdout)[0]
    assert actual['Id'] == proof['config'] and any(value.endswith('@' + proof['manifest']) for value in actual['RepoDigests']), 'Native engine SDK identity differs'
    return proof, context


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['compiler-plan', 'sdk-invocation', 'parent-proof', 'output']:
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--unit', required=True)
    parser.add_argument('--image-repo', required=True)
    parser.add_argument('--gpu-source', type=Path)
    parser.add_argument('--gpu-source-proof', type=Path)
    args = parser.parse_args()
    plan = json.loads(args.compiler_plan.read_text())
    source = Path(plan['source'])
    full_path = Path(plan['full_source_preflight_proof'])
    full_source(source, full_path, plan['source_revision'])
    parent, context = sdk_parent(plan, args.sdk_invocation, args.parent_proof)
    sdk = json.loads(args.sdk_invocation.read_text())
    assert sdk['source'] == str(source) and sdk['source_revision'] == plan['source_revision'], 'GPU must use the exact reviewed SDK source'
    source, revision, full_path, source_review = select_gpu_source(plan, args.gpu_source, args.gpu_source_proof)
    record = {'source_revision':revision, 'parent_source_revision':plan['source_revision'],
              'GPU_source_review':source_review, 'variant':'rocm', 'stage':'gpu',
              'source_full_preflight_proof':str(full_path), 'source_full_preflight_sha256':sha(full_path),
              'source_full_preflight_passed':True, 'producer_source_unchanged':True,
              'SDK_invocation':str(args.sdk_invocation.resolve()), 'SDK_invocation_sha256':sha(args.sdk_invocation),
              'parent_OCI_proof':str(args.parent_proof.resolve()), 'parent_OCI_proof_sha256':sha(args.parent_proof),
              'parent_manifest':parent['manifest'], 'parent_config':parent['config'], 'parent_OCI_index_sha256':parent['index_sha256'],
              'SDK_layers_rehashed':parent['layers'], 'compiler_layers_rehashed':26,
              'launcher_inputs_sha256':{path.name:sha(path) for path in [Path(__file__), Path(__file__).with_name('normal_stage_launch.py')]},
              'GPU_or_final_image_acceptance':False, 'scope':__doc__}
    reference = sdk['image'].rsplit(':', 1)[0] + '@' + parent['manifest']
    return launch_stage(source, args.output.resolve(), args.unit, args.image_repo, 'gpu', 'amd64', context,
                        reference, plan['required_bytes'], record, variant='rocm')


if __name__ == '__main__':
    raise SystemExit(main())
