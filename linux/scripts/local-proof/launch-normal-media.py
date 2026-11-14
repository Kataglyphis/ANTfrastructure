#!/usr/bin/env python3
"""Launch ordinary ROCm amd64 Media with both required Wasm modes from its verified native GPU parent; no final acceptance."""

import argparse
from pathlib import Path

from gpu_handoff_profile import gpu_layout, load_gpu
from normal_stage_launch import downstream_record, launch_stage


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('compiler-plan', 'gpu-invocation', 'parent-proof', 'output'):
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--unit', required=True)
    parser.add_argument('--image-repo', required=True)
    args = parser.parse_args()
    plan, invocation, sdk = load_gpu(args.compiler_plan, args.gpu_invocation)
    parent, context = gpu_layout(args.parent_proof, args.gpu_invocation, invocation, sdk)
    record = downstream_record(invocation, args.gpu_invocation, args.parent_proof, parent, 'GPU')
    record.update(GPU_layers_rehashed=parent['layers'], SDK_layers_matched=sdk['layers'],
                  ORT_WEB_REQUIRED=1, ORT_WASM_WEBGPU_FLAVORS=True, scope=__doc__, GPU_or_FINAL_acceptance=False)
    reference = invocation['image'].rsplit(':', 1)[0] + '@' + parent['manifest']
    return launch_stage(Path(invocation['source']), args.output.resolve(), args.unit, args.image_repo, 'media', 'amd64',
                        context, reference, plan['required_bytes'], record, variant='rocm')


if __name__ == '__main__':
    raise SystemExit(main())
