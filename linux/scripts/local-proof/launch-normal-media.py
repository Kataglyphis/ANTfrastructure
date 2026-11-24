#!/usr/bin/env python3
"""Launch ordinary ROCm or NVIDIA Media with both required Wasm modes from its native GPU parent; no final acceptance."""

import argparse
from pathlib import Path

from gpu_handoff_profile import gpu_layout, load_gpu
from media_source_profile import select_media_source
from native_oci_layout import sha
from normal_stage_launch import MEDIA_REQUIRED_BYTES, downstream_record, launch_stage


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('compiler-plan', 'gpu-invocation', 'parent-proof', 'output'):
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--unit', required=True)
    parser.add_argument('--image-repo', required=True)
    parser.add_argument('--variant', choices=('rocm', 'nvidia'), default='rocm')
    parser.add_argument('--media-source', type=Path)
    parser.add_argument('--media-source-proof', type=Path)
    args = parser.parse_args()
    if (args.media_source is None) != (args.media_source_proof is None):
        parser.error('--media-source and --media-source-proof go together')
    if args.variant == 'nvidia':
        if args.media_source is not None:
            parser.error('an alternate Media source is reviewed for ROCm only')
        from nvidia_handoff_profile import launch_nvidia_media

        return launch_nvidia_media(args.compiler_plan, args.gpu_invocation, args.parent_proof,
                                   args.output.resolve(), args.unit, args.image_repo)
    plan, invocation, sdk = load_gpu(args.compiler_plan, args.gpu_invocation)
    parent, context = gpu_layout(args.parent_proof, args.gpu_invocation, invocation, sdk)
    record = downstream_record(invocation, args.gpu_invocation, args.parent_proof, parent, 'GPU')
    record.update(GPU_layers_rehashed=parent['layers'], SDK_layers_matched=sdk['layers'],
                  ORT_WEB_REQUIRED=1, ORT_WASM_WEBGPU_FLAVORS=True, scope=__doc__, GPU_or_FINAL_acceptance=False)
    source = Path(invocation['source'])
    if args.media_source is not None:
        source, revision, proof, review = select_media_source(invocation, args.media_source, args.media_source_proof)
        record.update(source_revision=revision, source_full_preflight_proof=str(proof),
                      source_full_preflight_sha256=sha(proof), Media_source_review=review)
    reference = invocation['image'].rsplit(':', 1)[0] + '@' + parent['manifest']
    return launch_stage(source, args.output.resolve(), args.unit, args.image_repo, 'media', 'amd64',
                        context, reference, max(plan['required_bytes'], MEDIA_REQUIRED_BYTES), record, variant='rocm')


if __name__ == '__main__':
    raise SystemExit(main())
